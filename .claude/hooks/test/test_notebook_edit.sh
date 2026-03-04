#!/bin/bash
# test_notebook_edit.sh - Tests BUG-8: NotebookEdit coverage gap
#
# Verifies that:
# - file_path extraction works in protect_linter_configs.sh (regression)
# - notebook_path fallback works when file_path is absent
# - .ipynb files exit cleanly from multi_linter.sh (no subprocess)
# - Protected .claude/ paths still block via notebook_path
#
# Usage: bash .claude/tests/hooks/test_notebook_edit.sh

set -euo pipefail

# --- Path resolution ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_dir="$(cd "${script_dir}/../../hooks" && pwd)"

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

# --- Gate: jaq required ---
if ! command -v jaq >/dev/null 2>&1; then
  printf "SKIP: jaq not installed\n"
  exit 0
fi

# --- Helper: run protect hook ---
run_protect() {
  local json_input="$1"
  local project_dir="${2:-${tmp_dir}/default_project}"
  mkdir -p "${project_dir}/.claude/hooks"
  echo "${json_input}" \
    | CLAUDE_PROJECT_DIR="${project_dir}" \
      bash "${hook_dir}/protect_linter_configs.sh" 2>/dev/null
}

# --- Helper: run multi_linter hook ---
run_linter() {
  local json_input="$1"
  local project_dir="${2:-${tmp_dir}/default_project}"
  mkdir -p "${project_dir}/.claude/hooks"
  echo "${json_input}" \
    | CLAUDE_PROJECT_DIR="${project_dir}" \
      bash "${hook_dir}/multi_linter.sh" 2>/dev/null
}

# === Begin tests ===
printf "=== BUG-8: NotebookEdit Coverage Tests ===\n"

# ============================================================================
# Test 8a: file_path extraction in protect_linter_configs.sh (regression)
# ============================================================================
printf "\n--- test8a: file_path extraction still works ---\n"

t8a_out=$(run_protect '{"tool_input":{"file_path":"/home/user/.ruff.toml"}}' "${tmp_dir}/t8a")
t8a_decision=$(echo "${t8a_out}" | jaq -r '.decision' 2>/dev/null)

assert "t8a_file_path" \
  "[[ '${t8a_decision}' == 'block' ]]" \
  "file_path extraction blocks .ruff.toml" \
  "file_path extraction failed (decision=${t8a_decision})"

# ============================================================================
# Test 8b: notebook_path fallback in protect_linter_configs.sh
# ============================================================================
printf "\n--- test8b: notebook_path fallback in protect hook ---\n"

# When file_path is absent but notebook_path is present (NotebookEdit scenario)
t8b_out=$(run_protect '{"tool_input":{"notebook_path":"/home/user/.claude/hooks/bad.sh"}}' "${tmp_dir}/t8b")
t8b_decision=$(echo "${t8b_out}" | jaq -r '.decision' 2>/dev/null)

assert "t8b_notebook_path" \
  "[[ '${t8b_decision}' == 'block' ]]" \
  "notebook_path fallback blocks .claude/hooks/ path" \
  "notebook_path fallback failed (decision=${t8b_decision})"

# ============================================================================
# Test 8c: notebook_path fallback in multi_linter.sh
# ============================================================================
printf "\n--- test8c: notebook_path extraction in multi_linter.sh ---\n"

# Create a notebook file for the linter to find
t8c_nb="${tmp_dir}/t8c_notebook.ipynb"
printf '{"cells":[]}' >"${t8c_nb}"

run_linter "{\"tool_input\":{\"notebook_path\":\"${t8c_nb}\"}}" "${tmp_dir}/t8c_project"
# Should exit cleanly (notebook = no-lint)
t8c_exit=$?

assert "t8c_clean_exit" \
  "[[ ${t8c_exit} -eq 0 ]]" \
  "notebook_path extraction exits cleanly" \
  "notebook_path extraction failed (exit=${t8c_exit})"

# ============================================================================
# Test 8d: .ipynb exits cleanly with no subprocess attempt
# ============================================================================
printf "\n--- test8d: .ipynb exits cleanly (no lint) ---\n"

t8d_nb="${tmp_dir}/t8d_notebook.ipynb"
printf '{"cells":[]}' >"${t8d_nb}"

run_linter "{\"tool_input\":{\"file_path\":\"${t8d_nb}\"}}" "${tmp_dir}/t8d_project"
t8d_exit=$?

assert "t8d_clean_exit" \
  "[[ ${t8d_exit} -eq 0 ]]" \
  ".ipynb exits cleanly" \
  ".ipynb failed (exit=${t8d_exit})"

# ============================================================================
# Test 8e: .claude/hooks/ blocks through notebook_path
# ============================================================================
printf "\n--- test8e: .claude/hooks/ blocks through notebook_path ---\n"

t8e_out=$(run_protect '{"tool_input":{"notebook_path":".claude/hooks/multi_linter.sh"}}' "${tmp_dir}/t8e")
t8e_decision=$(echo "${t8e_out}" | jaq -r '.decision' 2>/dev/null)

assert "t8e_block_hooks" \
  "[[ '${t8e_decision}' == 'block' ]]" \
  ".claude/hooks/ blocked via notebook_path" \
  ".claude/hooks/ NOT blocked via notebook_path (decision=${t8e_decision})"

# ============================================================================
# Test 8f: .claude/subprocess-settings.json blocks through notebook_path
# ============================================================================
printf "\n--- test8f: subprocess-settings blocks through notebook_path ---\n"

t8f_out=$(run_protect '{"tool_input":{"notebook_path":".claude/subprocess-settings.json"}}' "${tmp_dir}/t8f")
t8f_decision=$(echo "${t8f_out}" | jaq -r '.decision' 2>/dev/null)

assert "t8f_block_subprocess_settings" \
  "[[ '${t8f_decision}' == 'block' ]]" \
  "subprocess-settings.json blocked via notebook_path" \
  "subprocess-settings.json NOT blocked via notebook_path (decision=${t8f_decision})"

# ============================================================================
# Test 8g: unrelated notebook approves
# ============================================================================
printf "\n--- test8g: unrelated notebook approves ---\n"

t8g_out=$(run_protect '{"tool_input":{"notebook_path":"/home/user/project/analysis.ipynb"}}' "${tmp_dir}/t8g")
t8g_decision=$(echo "${t8g_out}" | jaq -r '.decision' 2>/dev/null)

assert "t8g_approve" \
  "[[ '${t8g_decision}' == 'approve' ]]" \
  "unrelated notebook approved" \
  "unrelated notebook NOT approved (decision=${t8g_decision})"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
