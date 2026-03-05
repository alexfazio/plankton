#!/bin/bash
# test_pr2_regressions.sh - Regression tests for PR #2 integration
#
# Verifies:
# T1: protect_linter_configs.sh approves non-protected files with valid JSON
# T2: multi_linter.sh returns valid JSON when each language is disabled
# T3: hook_enabled=false path returns valid JSON (not bare exit)
# T4: Security exclusion path uses correct function (no get_exclusions)
# T5: *.Dockerfile pattern exists in lint dispatch
# T6: TypeScript disable path returns valid JSON
#
# Usage: bash .claude/tests/hooks/test_pr2_regressions.sh
# shellcheck disable=SC2016  # jaq variables ($lang, $fp) intentionally in single quotes

set -euo pipefail

# --- Path resolution ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_dir="$(cd "${script_dir}/.." && pwd)"
protect_hook="${hook_dir}/protect_linter_configs.sh"
lint_hook="${hook_dir}/multi_linter.sh"

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

# --- Helper: set up a project dir with config ---
setup_project() {
  local project_dir="$1"
  local config_json="${2:-}"
  mkdir -p "${project_dir}/.claude/hooks"
  if [[ -n "${config_json}" ]]; then
    printf '%s\n' "${config_json}" >"${project_dir}/.claude/hooks/config.json"
  fi
}

# === T1: Non-protected file emits approve JSON ===
printf "\n=== T1: Non-protected file approve JSON ===\n"

t1_project="${tmp_dir}/t1"
setup_project "${t1_project}"

t1_json='{"tool_input":{"file_path":"README.md"}}'
t1_out=""
t1_exit=0
t1_out=$(echo "${t1_json}" \
  | CLAUDE_PROJECT_DIR="${t1_project}" \
    bash "${protect_hook}" 2>/dev/null) || t1_exit=$?

t1_decision=$(echo "${t1_out}" | jaq -r '.decision' 2>/dev/null || echo "")

assert "t1_exit" "[[ ${t1_exit} -eq 0 ]]" \
  "exit 0 for non-protected file" \
  "exit ${t1_exit} (expected 0)"
assert "t1_json" "[[ -n '${t1_out}' ]]" \
  "stdout not empty" \
  "stdout is empty (no JSON emitted)"
assert "t1_approve" "[[ '${t1_decision}' == 'approve' ]]" \
  "decision=approve" \
  "decision='${t1_decision}' (expected approve)"

# === T2: Language-disable paths emit valid JSON ===
printf "\n=== T2: Language-disable paths ===\n"

test_language_disable() {
  local lang="$1"
  local ext="$2"
  local tag="t2_${lang}"

  local project_dir="${tmp_dir}/${tag}"
  local config
  config=$(jaq -n --arg lang "${lang}" \
    '{languages: {($lang): false}}' 2>/dev/null)
  setup_project "${project_dir}" "${config}"

  # Create a dummy file
  local test_file="${project_dir}/test_file${ext}"
  printf 'dummy\n' >"${test_file}"

  local payload
  payload=$(jaq -cn --arg fp "${test_file}" \
    '{tool_name: "Edit", tool_input: {file_path: $fp}}')

  local out="" exit_code=0
  out=$(echo "${payload}" \
    | CLAUDE_PROJECT_DIR="${project_dir}" \
      HOOK_SKIP_SUBPROCESS=1 \
      bash "${lint_hook}" 2>/dev/null) || exit_code=$?

  local has_continue
  has_continue=$(echo "${out}" | jaq -r '.continue' 2>/dev/null || echo "")

  assert "${tag}_exit" "[[ ${exit_code} -eq 0 ]]" \
    "${lang} disabled: exit 0" \
    "${lang} disabled: exit ${exit_code} (expected 0)"
  assert "${tag}_json" "[[ '${has_continue}' == 'true' ]]" \
    "${lang} disabled: {\"continue\":true}" \
    "${lang} disabled: stdout='${out}' (expected continue:true)"
}

test_language_disable "python" ".py"
test_language_disable "shell" ".sh"
test_language_disable "yaml" ".yml"
test_language_disable "json" ".json"
test_language_disable "dockerfile" ".dockerfile"
test_language_disable "toml" ".toml"
test_language_disable "markdown" ".md"

# === T3: hook_enabled=false emits valid JSON ===
printf "\n=== T3: hook_enabled=false path ===\n"

t3_project="${tmp_dir}/t3"
setup_project "${t3_project}" '{"hook_enabled": false}'
t3_file="${t3_project}/test.py"
printf 'x = 1\n' >"${t3_file}"

t3_payload=$(jaq -cn --arg fp "${t3_file}" \
  '{tool_name: "Edit", tool_input: {file_path: $fp}}')

t3_out="" t3_exit=0
t3_out=$(echo "${t3_payload}" \
  | CLAUDE_PROJECT_DIR="${t3_project}" \
    HOOK_SKIP_SUBPROCESS=1 \
    bash "${lint_hook}" 2>/dev/null) || t3_exit=$?

t3_continue=$(echo "${t3_out}" | jaq -r '.continue' 2>/dev/null || echo "")

assert "t3_exit" "[[ ${t3_exit} -eq 0 ]]" \
  "hook_enabled=false: exit 0" \
  "hook_enabled=false: exit ${t3_exit}"
assert "t3_json" "[[ '${t3_continue}' == 'true' ]]" \
  "hook_enabled=false: {\"continue\":true}" \
  "hook_enabled=false: stdout='${t3_out}' (missing JSON)"

# === T4: Security exclusion path — no undefined function ===
printf "\n=== T4: Security exclusion path ===\n"

t4_project="${tmp_dir}/t4"
setup_project "${t4_project}"
mkdir -p "${t4_project}/.venv"
t4_file="${t4_project}/.venv/bad.py"
printf 'import os; os.system("rm -rf /")\n' >"${t4_file}"

t4_payload=$(jaq -cn --arg fp "${t4_file}" \
  '{tool_name: "Edit", tool_input: {file_path: $fp}}')

t4_stderr=""
_t4_exit=0
_t4_out=$(echo "${t4_payload}" \
  | CLAUDE_PROJECT_DIR="${t4_project}" \
    HOOK_SKIP_SUBPROCESS=1 \
    bash "${lint_hook}" 2>"${tmp_dir}/t4_stderr") || _t4_exit=$?
t4_stderr=$(cat "${tmp_dir}/t4_stderr")

# Check stderr does NOT contain "get_exclusions: command not found"
t4_has_undef=""
if echo "${t4_stderr}" | grep -q "get_exclusions.*not found" 2>/dev/null; then
  t4_has_undef="yes"
fi

assert "t4_no_undef" "[[ -z '${t4_has_undef}' ]]" \
  "no undefined get_exclusions call" \
  "get_exclusions: command not found in stderr"

# === T5: *.Dockerfile in lint dispatch ===
printf "\n=== T5: *.Dockerfile pattern ===\n"

# Static check: grep the lint dispatch case block for *.Dockerfile
t5_has_pattern=""
if grep -q '\*\.Dockerfile' "${lint_hook}" 2>/dev/null; then
  t5_has_pattern="yes"
fi

assert "t5_pattern" "[[ '${t5_has_pattern}' == 'yes' ]]" \
  "*.Dockerfile in lint dispatch" \
  "*.Dockerfile missing from lint dispatch case"

# === T6: TypeScript disable emits valid JSON ===
printf "\n=== T6: TypeScript disable path ===\n"

t6_project="${tmp_dir}/t6"
t6_config='{"languages":{"typescript":{"enabled":false}}}'
setup_project "${t6_project}" "${t6_config}"
t6_file="${t6_project}/test.ts"
printf 'const x: number = 1;\n' >"${t6_file}"

t6_payload=$(jaq -cn --arg fp "${t6_file}" \
  '{tool_name: "Edit", tool_input: {file_path: $fp}}')

t6_out="" t6_exit=0
t6_out=$(echo "${t6_payload}" \
  | CLAUDE_PROJECT_DIR="${t6_project}" \
    HOOK_SKIP_SUBPROCESS=1 \
    bash "${lint_hook}" 2>/dev/null) || t6_exit=$?

t6_continue=$(echo "${t6_out}" | jaq -r '.continue' 2>/dev/null || echo "")

assert "t6_exit" "[[ ${t6_exit} -eq 0 ]]" \
  "ts disabled: exit 0" \
  "ts disabled: exit ${t6_exit}"
assert "t6_json" "[[ '${t6_continue}' == 'true' ]]" \
  "ts disabled: {\"continue\":true}" \
  "ts disabled: stdout='${t6_out}' (missing JSON)"

# === Summary ===
printf "\n=== PR #2 Regression Tests: %d passed, %d failed ===\n" "${passed}" "${failed}"
if [[ ${failed} -gt 0 ]]; then
  exit 1
fi
exit 0
