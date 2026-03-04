#!/bin/bash
# test_step0_reproduction.sh - Step 0: Reproduce the original subprocess permission bug
#
# Confirms that:
# 1. The OLD invocation (no --dangerously-skip-permissions) silently fails
# 2. The NEW invocation (with the fix) successfully modifies the file
# 3. Stderr logging captures diagnostic information in both cases
#
# Requires: claude binary on PATH, ANTHROPIC_API_KEY set, network access
#
# Usage: bash .claude/tests/hooks/test_step0_reproduction.sh

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

# --- Settings file (no hooks, skip permission prompt) ---
settings_file="${tmp_dir}/subprocess-settings.json"
cat >"${settings_file}" <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
EOF

# === Begin tests ===
printf "=== Step 0: Reproduction of Subprocess Permission Bug ===\n"
printf "NOTE: These tests make live API calls (~60s each)\n\n"

# --- Create a target file with known content ---
target_content='ORIGINAL_CONTENT_LINE_ONE
ORIGINAL_CONTENT_LINE_TWO'

edit_prompt="Use the Edit tool to replace the text 'ORIGINAL_CONTENT_LINE_ONE' with 'FIXED_CONTENT_LINE_ONE' in the file"

# ============================================================================
# Test s0a: OLD invocation — no --dangerously-skip-permissions (should fail)
# ============================================================================
printf '\n%s\n' "--- s0a: OLD invocation (no skip-permissions) — expect failure ---"

s0a_file="${tmp_dir}/s0a_target.txt"
printf '%s\n' "${target_content}" >"${s0a_file}"
s0a_hash_before=$(cksum "${s0a_file}" 2>/dev/null || true)

s0a_stderr="${tmp_dir}/s0a_stderr.txt"
s0a_exit=0

# OLD invocation: mirrors pre-fix multi_linter.sh:403-408
timeout 60 claude -p \
  "${edit_prompt} ${s0a_file}. Do not add any other text." \
  --settings "${settings_file}" \
  --allowedTools "Edit,Read" \
  --max-turns 3 \
  --model haiku \
  </dev/null >"${tmp_dir}/s0a_stdout.txt" 2>"${s0a_stderr}" || s0a_exit=$?

s0a_hash_after=$(cksum "${s0a_file}" 2>/dev/null || true)

printf "  exit code: %d\n" "${s0a_exit}"
printf "  file hash before: %s\n" "${s0a_hash_before}"
printf "  file hash after:  %s\n" "${s0a_hash_after}"

assert "s0a_file_unchanged" \
  "[[ '${s0a_hash_before}' == '${s0a_hash_after}' ]]" \
  "file unchanged (subprocess blocked without skip-permissions — bug reproduced)" \
  "file WAS modified — subprocess can edit without skip-permissions (unexpected)"

assert "s0a_nonzero_or_unchanged" \
  "[[ ${s0a_exit} -ne 0 ]] || [[ '${s0a_hash_before}' == '${s0a_hash_after}' ]]" \
  "subprocess exited non-zero (${s0a_exit}) or file unchanged" \
  "subprocess exited 0 AND file unchanged — silent failure confirmed"

# ============================================================================
# Test s0b: NEW invocation — with --dangerously-skip-permissions (should work)
# ============================================================================
printf "\n--- s0b: NEW invocation (with skip-permissions) — expect success ---\n"

s0b_file="${tmp_dir}/s0b_target.txt"
printf '%s\n' "${target_content}" >"${s0b_file}"
s0b_hash_before=$(cksum "${s0b_file}" 2>/dev/null || true)

s0b_stderr="${tmp_dir}/s0b_stderr.txt"
s0b_exit=0

# NEW invocation: mirrors post-fix multi_linter.sh:549-556
timeout 60 claude -p \
  "${edit_prompt} ${s0b_file}. Do not add any other text." \
  --dangerously-skip-permissions \
  --settings "${settings_file}" \
  --disallowedTools "Bash,WebFetch,WebSearch,NotebookEdit,Task,Glob,Grep,Write" \
  --max-turns 3 \
  --model haiku \
  </dev/null >"${tmp_dir}/s0b_stdout.txt" 2>"${s0b_stderr}" || s0b_exit=$?

s0b_hash_after=$(cksum "${s0b_file}" 2>/dev/null || true)

printf "  exit code: %d\n" "${s0b_exit}"
printf "  file hash before: %s\n" "${s0b_hash_before}"
printf "  file hash after:  %s\n" "${s0b_hash_after}"

assert "s0b_file_modified" \
  "grep -q 'FIXED_CONTENT_LINE_ONE' '${s0b_file}'" \
  "file modified: ORIGINAL → FIXED (fix works)" \
  "file NOT modified — fix may not be working (exit=${s0b_exit})"

assert "s0b_exit_zero" \
  "[[ ${s0b_exit} -eq 0 ]]" \
  "subprocess exited 0 (success)" \
  "subprocess exited ${s0b_exit} (non-zero)"

# --- Diagnostic output ---
printf "\n--- Diagnostic: s0a stderr (last 15 lines) ---\n"
tail -15 "${s0a_stderr}" 2>/dev/null || printf "(empty)\n"
printf "\n--- Diagnostic: s0b stderr (last 15 lines) ---\n"
tail -15 "${s0b_stderr}" 2>/dev/null || printf "(empty)\n"

# --- Reproduction summary ---
printf "\n--- Step 0 Reproduction Result ---\n"
if [[ "${s0a_hash_before}" == "${s0a_hash_after}" ]] && grep -q 'FIXED_CONTENT_LINE_ONE' "${s0b_file}" 2>/dev/null; then
  printf "BUG REPRODUCED AND FIX CONFIRMED:\n"
  printf "  - OLD invocation: subprocess blocked (file unchanged)\n"
  printf "  - NEW invocation: subprocess works (file modified)\n"
  printf "  - --dangerously-skip-permissions is REQUIRED for headless subprocess tool access\n"
elif [[ "${s0a_hash_before}" != "${s0a_hash_after}" ]]; then
  printf "BUG NOT REPRODUCED: OLD invocation modified the file.\n"
  printf "Permission may propagate from parent session. See P0 test for details.\n"
else
  printf "PARTIAL: OLD invocation blocked but NEW invocation also failed.\n"
  printf "Check stderr diagnostics above for API/network issues.\n"
fi

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
