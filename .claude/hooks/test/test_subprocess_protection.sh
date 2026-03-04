#!/bin/bash
# test_subprocess_protection.sh - Tests BUG-9: subprocess settings file protection
#
# Verifies protect_linter_configs.sh (PreToolUse):
# - Blocks relative .claude/settings.json paths (BUG-9a)
# - Blocks relative .claude/settings.local.json paths (BUG-9a)
# - Blocks relative .claude/subprocess-settings.json paths (BUG-9)
# - Blocks absolute-style .claude/* paths (existing)
# - Blocks config-specified external subprocess settings file (BUG-9)
# - Resolves symlinked paths for config-specified settings
# - Approves unrelated files
# - Existing .claude/hooks/* protection still works
#
# Verifies stop_config_guardian.sh (Stop hook):
# - Detects modified .claude/subprocess-settings.json via git diff
# - Approves unmodified repos
# - Bypasses check when stop_hook_active=true
#
# Usage: bash .claude/tests/hooks/test_subprocess_protection.sh

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

# --- Helper: run protect hook and capture output ---
run_protect() {
  local file_path="$1"
  local project_dir="${2:-${tmp_dir}/default_project}"
  local config_content="${3:-}"

  # Setup project dir with optional config
  mkdir -p "${project_dir}/.claude/hooks"
  if [[ -n "${config_content}" ]]; then
    printf '%s\n' "${config_content}" >"${project_dir}/.claude/hooks/config.json"
  fi

  local json
  json=$(printf '{"tool_input":{"file_path":"%s"}}' "${file_path}")

  echo "${json}" \
    | CLAUDE_PROJECT_DIR="${project_dir}" \
      bash "${hook_dir}/protect_linter_configs.sh" 2>/dev/null
}

# === Begin tests ===
printf "=== BUG-9: Subprocess Settings Protection Tests ===\n"

# ============================================================================
# Test 9a: relative .claude/settings.json blocks
# ============================================================================
printf "\n--- test9a: relative .claude/settings.json blocks ---\n"

t9a_out=$(run_protect ".claude/settings.json" "${tmp_dir}/t9a")
t9a_decision=$(echo "${t9a_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9a_block" \
  "[[ '${t9a_decision}' == 'block' ]]" \
  "relative .claude/settings.json blocked" \
  "relative .claude/settings.json NOT blocked (decision=${t9a_decision})"

# ============================================================================
# Test 9b: absolute-style .claude/settings.json blocks
# ============================================================================
printf "\n--- test9b: absolute-style .claude/settings.json blocks ---\n"

t9b_out=$(run_protect "/home/user/project/.claude/settings.json" "${tmp_dir}/t9b")
t9b_decision=$(echo "${t9b_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9b_block" \
  "[[ '${t9b_decision}' == 'block' ]]" \
  "absolute .claude/settings.json blocked" \
  "absolute .claude/settings.json NOT blocked (decision=${t9b_decision})"

# ============================================================================
# Test 9c: relative .claude/settings.local.json blocks
# ============================================================================
printf "\n--- test9c: relative .claude/settings.local.json blocks ---\n"

t9c_out=$(run_protect ".claude/settings.local.json" "${tmp_dir}/t9c")
t9c_decision=$(echo "${t9c_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9c_block" \
  "[[ '${t9c_decision}' == 'block' ]]" \
  "relative .claude/settings.local.json blocked" \
  "relative .claude/settings.local.json NOT blocked (decision=${t9c_decision})"

# ============================================================================
# Test 9d: relative .claude/subprocess-settings.json blocks
# ============================================================================
printf "\n--- test9d: relative .claude/subprocess-settings.json blocks ---\n"

t9d_out=$(run_protect ".claude/subprocess-settings.json" "${tmp_dir}/t9d")
t9d_decision=$(echo "${t9d_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9d_block" \
  "[[ '${t9d_decision}' == 'block' ]]" \
  "relative .claude/subprocess-settings.json blocked" \
  "relative .claude/subprocess-settings.json NOT blocked (decision=${t9d_decision})"

# ============================================================================
# Test 9e: absolute-style .claude/subprocess-settings.json blocks
# ============================================================================
printf "\n--- test9e: absolute .claude/subprocess-settings.json blocks ---\n"

t9e_out=$(run_protect "/home/user/project/.claude/subprocess-settings.json" "${tmp_dir}/t9e")
t9e_decision=$(echo "${t9e_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9e_block" \
  "[[ '${t9e_decision}' == 'block' ]]" \
  "absolute .claude/subprocess-settings.json blocked" \
  "absolute .claude/subprocess-settings.json NOT blocked (decision=${t9e_decision})"

# ============================================================================
# Test 9f: config-specified external settings path (absolute) blocks
# ============================================================================
printf "\n--- test9f: config-specified external settings blocks ---\n"

EXTERNAL_CONFIG='{"subprocess":{"settings_file":"/opt/claude/custom-settings.json"}}'

t9f_out=$(run_protect "/opt/claude/custom-settings.json" "${tmp_dir}/t9f" "${EXTERNAL_CONFIG}")
t9f_decision=$(echo "${t9f_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9f_block" \
  "[[ '${t9f_decision}' == 'block' ]]" \
  "config-specified external settings blocked" \
  "config-specified external settings NOT blocked (decision=${t9f_decision})"

# ============================================================================
# Test 9g: config-specified external settings with tilde blocks
# ============================================================================
printf "\n--- test9g: config-specified tilde settings blocks ---\n"

# Isolate HOME for tilde expansion
t9g_home="${tmp_dir}/t9g_home"
mkdir -p "${t9g_home}"

TILDE_CONFIG='{"subprocess":{"settings_file":"~/custom-settings.json"}}'

# The hook should expand ~ to HOME and compare
t9g_out=$(HOME="${t9g_home}" run_protect "${t9g_home}/custom-settings.json" "${tmp_dir}/t9g" "${TILDE_CONFIG}")
t9g_decision=$(echo "${t9g_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9g_block" \
  "[[ '${t9g_decision}' == 'block' ]]" \
  "tilde-expanded external settings blocked" \
  "tilde-expanded external settings NOT blocked (decision=${t9g_decision})"

# ============================================================================
# Test 9h: unrelated file still approves
# ============================================================================
printf "\n--- test9h: unrelated file approves ---\n"

t9h_out=$(run_protect "/home/user/project/src/main.py" "${tmp_dir}/t9h")
t9h_decision=$(echo "${t9h_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9h_approve" \
  "[[ '${t9h_decision}' == 'approve' ]]" \
  "unrelated file approved" \
  "unrelated file NOT approved (decision=${t9h_decision})"

# ============================================================================
# Test 9i: existing .claude/hooks/* protection still works
# ============================================================================
printf "\n--- test9i: .claude/hooks/* protection works ---\n"

t9i_out=$(run_protect "/home/user/project/.claude/hooks/multi_linter.sh" "${tmp_dir}/t9i")
t9i_decision=$(echo "${t9i_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9i_block" \
  "[[ '${t9i_decision}' == 'block' ]]" \
  ".claude/hooks/* blocked" \
  ".claude/hooks/* NOT blocked (decision=${t9i_decision})"

# ============================================================================
# Test 9i2: .claude/hooks/test/* is explicitly allowed
# ============================================================================
printf "\n--- test9i2: .claude/hooks/test/* is allowed ---\n"

t9i2_out=$(run_protect "/home/user/project/.claude/hooks/test/test_docstring_branch.sh" "${tmp_dir}/t9i2")
t9i2_decision=$(echo "${t9i2_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9i2_approve" \
  "[[ '${t9i2_decision}' == 'approve' ]]" \
  ".claude/hooks/test/* approved" \
  ".claude/hooks/test/* NOT approved (decision=${t9i2_decision})"

# ============================================================================
# Test 9i3: .claude/hooks/test fixtures bypass basename-based linter config blocks
# ============================================================================
printf "\n--- test9i3: .claude/hooks/test fixtures are allowed ---\n"

t9i3_out=$(run_protect "/home/user/project/.claude/hooks/test/fixtures/.markdownlint.jsonc" "${tmp_dir}/t9i3")
t9i3_decision=$(echo "${t9i3_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9i3_approve" \
  "[[ '${t9i3_decision}' == 'approve' ]]" \
  ".claude/hooks/test fixture config approved" \
  ".claude/hooks/test fixture config NOT approved (decision=${t9i3_decision})"

# ============================================================================
# Test 9j: existing linter config protection still works outside hook tests
# ============================================================================
printf "\n--- test9j: linter config protection works ---\n"

t9j_out=$(run_protect "/home/user/project/.ruff.toml" "${tmp_dir}/t9j")
t9j_decision=$(echo "${t9j_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9j_block" \
  "[[ '${t9j_decision}' == 'block' ]]" \
  ".ruff.toml blocked" \
  ".ruff.toml NOT blocked (decision=${t9j_decision})"

# ============================================================================
# Stop-hook tests: stop_config_guardian.sh directly
# ============================================================================

# --- Helper: create a temp git repo with subprocess-settings.json ---
setup_git_repo() {
  local repo_dir="$1"
  mkdir -p "${repo_dir}/.claude/hooks"
  (cd "${repo_dir}" \
    && git init -q \
    && git config user.name "test" \
    && git config user.email "test@test" \
    && echo '{}' >".claude/hooks/config.json" \
    && echo '{}' >".claude/subprocess-settings.json" \
    && git add -A \
    && git commit -q -m "init")
}

# ============================================================================
# Test 9k: modified subprocess-settings.json blocks in Stop hook
# ============================================================================
printf "\n--- test9k: modified subprocess-settings.json blocks in Stop hook ---\n"

t9k_dir="${tmp_dir}/t9k_repo"
mkdir -p "${t9k_dir}"
setup_git_repo "${t9k_dir}"

# Modify the file (unstaged change)
echo '{"disableAllHooks": true}' >"${t9k_dir}/.claude/subprocess-settings.json"

t9k_out=$(cd "${t9k_dir}" && echo '{"stop_hook_active": false}' \
  | CLAUDE_PROJECT_DIR="${t9k_dir}" \
    bash "${hook_dir}/stop_config_guardian.sh" 2>/dev/null)
t9k_decision=$(echo "${t9k_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9k_block" \
  "[[ '${t9k_decision}' == 'block' ]]" \
  "modified subprocess-settings.json blocks in Stop hook" \
  "modified subprocess-settings.json NOT blocked in Stop hook (decision=${t9k_decision})"

# ============================================================================
# Test 9l: unmodified repo approves in Stop hook
# ============================================================================
printf "\n--- test9l: unmodified repo approves in Stop hook ---\n"

t9l_dir="${tmp_dir}/t9l_repo"
mkdir -p "${t9l_dir}"
setup_git_repo "${t9l_dir}"

# No modifications after commit
t9l_out=$(cd "${t9l_dir}" && echo '{"stop_hook_active": false}' \
  | CLAUDE_PROJECT_DIR="${t9l_dir}" \
    bash "${hook_dir}/stop_config_guardian.sh" 2>/dev/null)
t9l_decision=$(echo "${t9l_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9l_approve" \
  "[[ '${t9l_decision}' == 'approve' ]]" \
  "unmodified repo approves in Stop hook" \
  "unmodified repo NOT approved in Stop hook (decision=${t9l_decision})"

# ============================================================================
# Test 9m: stop_hook_active=true bypasses Stop hook
# ============================================================================
printf "\n--- test9m: stop_hook_active=true bypasses Stop hook ---\n"

# Reuse t9k_dir which has modifications — should still approve
t9m_out=$(cd "${t9k_dir}" && echo '{"stop_hook_active": true}' \
  | CLAUDE_PROJECT_DIR="${t9k_dir}" \
    bash "${hook_dir}/stop_config_guardian.sh" 2>/dev/null)
t9m_decision=$(echo "${t9m_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9m_approve" \
  "[[ '${t9m_decision}' == 'approve' ]]" \
  "stop_hook_active=true bypasses Stop hook" \
  "stop_hook_active=true did NOT bypass Stop hook (decision=${t9m_decision})"

# ============================================================================
# Test 9n: symlinked path to configured settings file blocks
# ============================================================================
printf "\n--- test9n: symlinked settings path blocks ---\n"

t9n_dir="${tmp_dir}/t9n"
mkdir -p "${t9n_dir}/real_dir"
echo '{}' >"${t9n_dir}/real_dir/custom-settings.json"
ln -s "${t9n_dir}/real_dir" "${t9n_dir}/linked_dir"

SYMLINK_CONFIG="{\"subprocess\":{\"settings_file\":\"${t9n_dir}/real_dir/custom-settings.json\"}}"

# Candidate accesses the same file through a symlink
t9n_out=$(run_protect "${t9n_dir}/linked_dir/custom-settings.json" "${tmp_dir}/t9n_project" "${SYMLINK_CONFIG}")
t9n_decision=$(echo "${t9n_out}" | jaq -r '.decision' 2>/dev/null)

assert "t9n_symlink_block" \
  "[[ '${t9n_decision}' == 'block' ]]" \
  "symlinked path to configured settings blocked" \
  "symlinked path NOT blocked (decision=${t9n_decision})"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
