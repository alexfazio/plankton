#!/usr/bin/env bash
# Test: REFERENCE.md accuracy after subprocess spec sync
# Verifies stale content removed and new content present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REFERENCE="${SCRIPT_DIR}/../REFERENCE.md"
PASS=0
FAIL=0
TOTAL=0

assert_no_match() {
  local label="$1" pattern="$2"
  TOTAL=$((TOTAL + 1))
  if grep -qE "${pattern}" "${REFERENCE}"; then
    echo "FAIL: ${label} — found match for: ${pattern}"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: ${label}"
    PASS=$((PASS + 1))
  fi
}

assert_match() {
  local label="$1" pattern="$2"
  TOTAL=$((TOTAL + 1))
  if grep -qE "${pattern}" "${REFERENCE}"; then
    echo "PASS: ${label}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${label} — no match for: ${pattern}"
    FAIL=$((FAIL + 1))
  fi
}

# --- Stale content must be absent ---

assert_no_match "1a: No model_selection.sonnet/opus_patterns" \
  "model_selection\.(sonnet|opus)_patterns"

assert_no_match "1b: No 3-tool list (Edit, Read, Bash)" \
  "Edit,\s*Read,\s*Bash|Edit, Read, Bash"

assert_no_match "1c: No bare no-hooks-settings.json (old default)" \
  '(^|/)no-hooks-settings\.json'

assert_no_match "1d: No 'user home directory' in subprocess context" \
  "user home directory.*NOT.*project|NOT.*project.*user home"

assert_no_match "1k: No Edit/Read/Bash in ASCII diagrams" \
  "Edit/Read/Bash"

assert_no_match "1l: No 'Ignored via || true' for exit codes" \
  "Ignored via.*\|\| true"

assert_no_match "1m: No 'overrides subprocess.timeout' (flat key)" \
  "overrides \`subprocess\.timeout\`"

# --- New content must be present ---

assert_match "1e: Contains subprocess.tiers documentation" \
  "subprocess\.tiers"

assert_match "1f: Contains --dangerously-skip-permissions" \
  "dangerously-skip-permissions"

assert_match "1g: Contains --disallowedTools" \
  "disallowedTools"

assert_match "1h: Contains skipDangerousModePermissionPrompt" \
  "skipDangerousModePermissionPrompt"

assert_match "1i: Contains per-tier tool scope (Edit,Read for haiku)" \
  "Edit,Read.*haiku|haiku.*Edit,Read"

assert_match "1j: Consolidated Phase 3 Subprocess section" \
  "## Phase 3 Subprocess"

echo ""
echo "Results: ${PASS}/${TOTAL} passed, ${FAIL} failed"
exit "${FAIL}"
