#!/bin/bash
# test_empirical_p0.sh - Empirical test: subprocess permission inheritance (P0)
#
# Tests whether shell-spawned `claude -p` subprocesses need
# --dangerously-skip-permissions to invoke tools. Requires:
# - claude binary on PATH
# - ANTHROPIC_API_KEY set
# - Network access for live API calls
#
# Usage: bash .claude/tests/hooks/test_empirical_p0.sh

set -euo pipefail

# --- Temp directory with cleanup trap ---
tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

# --- Counters ---
passed=0
failed=0

# --- Assertion helper ---
assert() {
  local tag="$1" cond="$2" pass_msg="$3" fail_msg="$4"
  if eval "${cond}"; then
    printf "  PASS %s: %s\n" "${tag}" "${pass_msg}"
    passed=$((passed + 1))
  else
    printf "  FAIL %s: %s\n" "${tag}" "${fail_msg}"
    failed=$((failed + 1))
  fi
}

# --- Gate: prerequisites ---
if ! command -v claude >/dev/null 2>&1; then
  printf "SKIP: claude binary not on PATH\n"
  exit 0
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  printf "SKIP: ANTHROPIC_API_KEY not set\n"
  exit 0
fi

# --- Create subprocess settings (no hooks, skip permission prompt) ---
settings_file="${tmp_dir}/subprocess-settings.json"
cat >"${settings_file}" <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
EOF

# === Begin tests ===
printf "=== Empirical P0: Permission Inheritance Tests ===\n"
printf "NOTE: These tests make live API calls (haiku model, ~30s each)\n\n"

# ============================================================================
# Test p0a: subprocess WITH --dangerously-skip-permissions can use Edit
# ============================================================================
printf '\n%s\n' "--- p0a: subprocess with skip-permissions can Edit ---"

p0a_file="${tmp_dir}/p0a_target.txt"
printf 'BEFORE_MARKER\n' >"${p0a_file}"

p0a_stderr="${tmp_dir}/p0a_stderr.txt"
p0a_exit=0
timeout 60 claude -p \
  "Use the Edit tool to replace the text 'BEFORE_MARKER' with 'AFTER_MARKER' in the file ${p0a_file}. Do not add any other text. Just make that one edit." \
  --dangerously-skip-permissions \
  --settings "${settings_file}" \
  --disallowedTools "Bash,WebFetch,WebSearch,NotebookEdit,Task,Glob,Grep,Write" \
  --max-turns 3 \
  --model haiku \
  </dev/null >"${tmp_dir}/p0a_stdout.txt" 2>"${p0a_stderr}" || p0a_exit=$?

printf "  exit code: %d\n" "${p0a_exit}"

assert "p0a_file_modified" \
  "grep -q 'AFTER_MARKER' '${p0a_file}'" \
  "file modified: BEFORE_MARKER → AFTER_MARKER (Edit tool works with skip-permissions)" \
  "file NOT modified — Edit tool may be blocked even with skip-permissions (exit=${p0a_exit})"

# ============================================================================
# Test p0b: subprocess WITHOUT --dangerously-skip-permissions cannot Edit
# ============================================================================
printf "\n--- p0b: subprocess without skip-permissions is blocked ---\n"

p0b_file="${tmp_dir}/p0b_target.txt"
printf 'BEFORE_MARKER\n' >"${p0b_file}"

p0b_stderr="${tmp_dir}/p0b_stderr.txt"
p0b_exit=0
timeout 60 claude -p \
  "Use the Edit tool to replace the text 'BEFORE_MARKER' with 'AFTER_MARKER' in the file ${p0b_file}. Do not add any other text. Just make that one edit." \
  --settings "${settings_file}" \
  --allowedTools "Edit,Read" \
  --max-turns 3 \
  --model haiku \
  </dev/null >"${tmp_dir}/p0b_stdout.txt" 2>"${p0b_stderr}" || p0b_exit=$?

printf "  exit code: %d\n" "${p0b_exit}"

assert "p0b_file_unchanged" \
  "grep -q 'BEFORE_MARKER' '${p0b_file}'" \
  "file unchanged: BEFORE_MARKER still present (subprocess blocked without skip-permissions)" \
  "file WAS modified — subprocess CAN edit without skip-permissions (P0 answer: inherits permissions)"

# --- Diagnostic output ---
printf "\n--- Diagnostic: p0a stderr ---\n"
head -20 "${p0a_stderr}" 2>/dev/null || printf "(empty)\n"
printf "\n--- Diagnostic: p0b stderr ---\n"
head -20 "${p0b_stderr}" 2>/dev/null || printf "(empty)\n"

# --- P0 Answer ---
printf "\n--- P0 Empirical Answer ---\n"
if grep -q 'AFTER_MARKER' "${p0a_file}" && grep -q 'BEFORE_MARKER' "${p0b_file}"; then
  printf "CONFIRMED: Shell-spawned subprocesses do NOT inherit bypassPermissions.\n"
  printf "--dangerously-skip-permissions is REQUIRED for subprocess tool access.\n"
elif grep -q 'AFTER_MARKER' "${p0a_file}" && grep -q 'AFTER_MARKER' "${p0b_file}"; then
  printf "UNEXPECTED: Subprocess CAN edit without skip-permissions.\n"
  printf "bypassPermissions MAY inherit to shell-spawned processes.\n"
  printf "The fix is still valid (explicit > implicit) but P0 answer differs from expectation.\n"
else
  printf "INCONCLUSIVE: Neither test produced expected results. Check stderr diagnostics above.\n"
fi

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
