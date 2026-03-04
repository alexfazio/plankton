#!/bin/bash
# test_pm_set_e_bug.sh - Regression test for BUG-5: set -e crash
#
# Verifies that enforce_package_managers.sh:
# - Outputs {"decision": "approve"} for clean (non-PM) commands
# - Exits 0 for clean commands
# - Still blocks PM commands when enforcement is enabled
#
# Usage: bash .claude/tests/hooks/test_pm_set_e_bug.sh

set -euo pipefail

# --- Path resolution ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_dir="$(cd "${script_dir}/../../hooks" && pwd)"

# --- Temp directory with cleanup ---
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

# --- Gate: jaq required ---
if ! command -v jaq >/dev/null 2>&1; then
  printf "SKIP: jaq not installed\n"
  exit 0
fi

# --- Helper: create project dir with PM config ---
setup_pm_project() {
  local pd="$1"
  local config_content="$2"
  mkdir -p "${pd}/.claude/hooks"
  printf '%s\n' "${config_content}" >"${pd}/.claude/hooks/config.json"
}

# PM enforcement config (both python and javascript enforced in block mode)
PM_CONFIG='{"package_managers": {"python": "uv", "javascript": "bun"}}'

# === Begin tests ===
printf "=== BUG-5: set -e crash regression tests ===\n"

# ============================================================================
# Test 5a: clean command produces approve JSON
# ============================================================================
printf "\n--- test5a: clean command (ls -la) produces approve JSON ---\n"

t5a_dir="${tmp_dir}/t5a"
setup_pm_project "${t5a_dir}" "${PM_CONFIG}"

t5a_out="${tmp_dir}/t5a_stdout.txt"
t5a_exit=0
echo '{"tool_input":{"command":"ls -la"}}' \
  | CLAUDE_PROJECT_DIR="${t5a_dir}" \
    bash "${hook_dir}/enforce_package_managers.sh" >"${t5a_out}" 2>/dev/null || t5a_exit=$?

assert "t5a_exit_zero" \
  "[[ ${t5a_exit} -eq 0 ]]" \
  "exit code is 0" \
  "exit code is ${t5a_exit} (set -e crash?)"

assert "t5a_has_output" \
  "[[ -s '${t5a_out}' ]]" \
  "hook produced output" \
  "hook produced NO output (set -e crash?)"

assert "t5a_approve_json" \
  "grep -q '\"decision\"' '${t5a_out}' && grep -q '\"approve\"' '${t5a_out}'" \
  "output contains approve decision" \
  "output missing approve decision"

# ============================================================================
# Test 5b: git status (another clean command) exits 0
# ============================================================================
printf "\n--- test5b: git status exits 0 with approve ---\n"

t5b_dir="${tmp_dir}/t5b"
setup_pm_project "${t5b_dir}" "${PM_CONFIG}"

t5b_out="${tmp_dir}/t5b_stdout.txt"
t5b_exit=0
echo '{"tool_input":{"command":"git status"}}' \
  | CLAUDE_PROJECT_DIR="${t5b_dir}" \
    bash "${hook_dir}/enforce_package_managers.sh" >"${t5b_out}" 2>/dev/null || t5b_exit=$?

assert "t5b_exit_zero" \
  "[[ ${t5b_exit} -eq 0 ]]" \
  "exit code is 0" \
  "exit code is ${t5b_exit}"

assert "t5b_approve" \
  "grep -q '\"approve\"' '${t5b_out}'" \
  "git status approved" \
  "git status NOT approved"

# ============================================================================
# Test 5c: pip install is still blocked
# ============================================================================
printf "\n--- test5c: pip install still blocked ---\n"

t5c_dir="${tmp_dir}/t5c"
setup_pm_project "${t5c_dir}" "${PM_CONFIG}"

t5c_out="${tmp_dir}/t5c_stdout.txt"
t5c_exit=0
echo '{"tool_input":{"command":"pip install requests"}}' \
  | CLAUDE_PROJECT_DIR="${t5c_dir}" \
    bash "${hook_dir}/enforce_package_managers.sh" >"${t5c_out}" 2>/dev/null || t5c_exit=$?

assert "t5c_exit_zero" \
  "[[ ${t5c_exit} -eq 0 ]]" \
  "exit code is 0" \
  "exit code is ${t5c_exit}"

assert "t5c_has_output" \
  "[[ -s '${t5c_out}' ]]" \
  "hook produced output" \
  "hook produced NO output"

assert "t5c_block_decision" \
  "grep -q '\"block\"' '${t5c_out}'" \
  "pip install blocked" \
  "pip install NOT blocked"

# ============================================================================
# Test 5d: no config.json — both modes default to "off", approve everything
# ============================================================================
printf "\n--- test5d: no config approves even PM commands ---\n"

t5d_dir="${tmp_dir}/t5d"
mkdir -p "${t5d_dir}" # NO .claude/hooks/config.json

t5d_out="${tmp_dir}/t5d_stdout.txt"
t5d_exit=0
echo '{"tool_input":{"command":"pip install requests"}}' \
  | CLAUDE_PROJECT_DIR="${t5d_dir}" \
    bash "${hook_dir}/enforce_package_managers.sh" >"${t5d_out}" 2>/dev/null || t5d_exit=$?

assert "t5d_exit_zero" \
  "[[ ${t5d_exit} -eq 0 ]]" \
  "exit code is 0" \
  "exit code is ${t5d_exit}"

assert "t5d_approve" \
  "grep -q '\"approve\"' '${t5d_out}'" \
  "pip install approved (no config = no enforcement)" \
  "pip install NOT approved"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
