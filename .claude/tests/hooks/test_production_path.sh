#!/bin/bash
# test_production_path.sh - Tests the multi-linter hook's production path
# (subprocess delegation) using a mock `claude` binary.
#
# Verifies that when HOOK_SKIP_SUBPROCESS is NOT set, the hook delegates
# to a claude subprocess and verifies results afterward.
#
# Usage:
#   bash .claude/tests/hooks/test_production_path.sh
#   # or from project root:
#   .claude/tests/hooks/test_production_path.sh

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

# --- Gate: shellcheck required for all tests ---
if ! command -v shellcheck >/dev/null 2>&1; then
  printf "SKIP: shellcheck not installed (required for production path tests)\n"
  exit 0
fi

# --- Isolate HOME from real user home ---
isolated_home="${tmp_dir}/home"
mkdir -p "${isolated_home}/.claude"
export HOME="${isolated_home}"

# --- Helper: create a fake CLAUDE_PROJECT_DIR with config ---
setup_project_dir() {
  local pd="$1"
  local config_content="$2"
  mkdir -p "${pd}/.claude/hooks"
  printf '%s\n' "${config_content}" >"${pd}/.claude/hooks/config.json"
  # Create subprocess settings file (project-local)
  cat >"${pd}/.claude/subprocess-settings.json" <<'SETTINGS_EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
SETTINGS_EOF
}

# --- Helper: create a shell file with ShellCheck violations ---
create_bad_shell_file() {
  local fp="$1"
  printf "#!/bin/bash\nunused=\"x\"\necho \$y\n" >"${fp}"
}

# === Begin tests ===
printf "=== Production Path Tests ===\n"

# ============================================================================
# Test 1: subprocess fixes nothing, hook reports remaining
# ============================================================================
printf "\n--- test1: subprocess fixes nothing, hook reports remaining ---\n"

test1_dir="${tmp_dir}/test1"
mkdir -p "${test1_dir}/bin"

# Mock claude: accepts any args, exits 0, does NOT modify files
cat >"${test1_dir}/bin/claude" <<'MOCK_EOF'
#!/bin/bash
# Mock claude that does nothing
exit 0
MOCK_EOF
chmod +x "${test1_dir}/bin/claude"

# Set up project dir with subprocess delegation enabled
setup_project_dir "${test1_dir}/project" '{"phases":{"subprocess_delegation":true}}'

# Create shell file with violations
test1_file="${test1_dir}/test.sh"
create_bad_shell_file "${test1_file}"

# Build JSON input
test1_json='{"tool_input":{"file_path":"'"${test1_file}"'"}}'

# Run the hook with mock claude on PATH
test1_stderr=""
test1_exit=0
test1_stderr=$(echo "${test1_json}" \
  | PATH="${test1_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test1_dir}/project" \
    HOOK_SESSION_PID="test1_$$" \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || test1_exit=$?

assert "test1_exit" "[[ ${test1_exit} -eq 2 ]]" \
  "exit code 2" "exit code ${test1_exit} (expected 2)"

assert "test1_stderr" "echo '${test1_stderr}' | grep -q 'violation(s) remain'" \
  "stderr contains 'violation(s) remain'" \
  "stderr missing 'violation(s) remain'"

assert "test1_feedback_marker" \
  "echo '${test1_stderr}' | grep -q '\\[hook:feedback-loop\\]'" \
  "stderr contains [hook:feedback-loop]" \
  "stderr missing [hook:feedback-loop]"

# ============================================================================
# Test 2: subprocess fixes all, hook exits 0
# ============================================================================
printf "\n--- test2: subprocess fixes all, hook exits 0 ---\n"

test2_dir="${tmp_dir}/test2"
mkdir -p "${test2_dir}/bin"

# Mock claude: finds file path from last arg, replaces with clean content
cat >"${test2_dir}/bin/claude" <<'MOCK_EOF'
#!/bin/bash
# Mock claude that fixes the file by replacing its content
# The hook passes the file as the last positional argument
target_file="${!#}"
if [[ -f "${target_file}" ]]; then
  printf '#!/bin/bash\necho "clean"\n' > "${target_file}"
fi
exit 0
MOCK_EOF
chmod +x "${test2_dir}/bin/claude"

# Set up project dir with subprocess delegation enabled
setup_project_dir "${test2_dir}/project" '{"phases":{"subprocess_delegation":true}}'

# Create shell file with violations
test2_file="${test2_dir}/test.sh"
create_bad_shell_file "${test2_file}"

# Build JSON input
test2_json='{"tool_input":{"file_path":"'"${test2_file}"'"}}'

# Run the hook with mock claude on PATH
test2_stderr=""
test2_exit=0
test2_stderr=$(echo "${test2_json}" \
  | PATH="${test2_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test2_dir}/project" \
    HOOK_SESSION_PID="test2_$$" \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || test2_exit=$?

assert "test2_exit" "[[ ${test2_exit} -eq 0 ]]" \
  "exit code 0" "exit code ${test2_exit} (expected 0)"

# Verify no [hook] error output (advisory/warning lines are OK)
test2_has_hook_error="false"
if echo "${test2_stderr}" | grep -q '^\[hook\] .*violation'; then
  test2_has_hook_error="true"
fi
assert "test2_no_violation_msg" "[[ '${test2_has_hook_error}' == 'false' ]]" \
  "no violation message in stderr" \
  "unexpected violation message in stderr"

# ============================================================================
# Test 3: subprocess not found, hook warns and continues
# ============================================================================
printf "\n--- test3: subprocess not found, hook warns and continues ---\n"

test3_dir="${tmp_dir}/test3"
mkdir -p "${test3_dir}"

# Set up project dir with subprocess delegation enabled
setup_project_dir "${test3_dir}/project" '{"phases":{"subprocess_delegation":true}}'

# Create shell file with violations
test3_file="${test3_dir}/test.sh"
create_bad_shell_file "${test3_file}"

# Build JSON input
test3_json='{"tool_input":{"file_path":"'"${test3_file}"'"}}'

# Build a PATH with symlinks to all needed tools EXCEPT claude.
# This is necessary because claude and the linters may share a directory
# (e.g., /opt/homebrew/bin), so we cannot simply exclude directories.
test3_bin="${test3_dir}/bin"
mkdir -p "${test3_bin}"
for cmd in jaq shellcheck shfmt bash cat grep sed wc mktemp mv rm mkdir touch cmp sort tr dirname tail head; do
  cmd_path=$(command -v "${cmd}" 2>/dev/null || true)
  if [[ -n "${cmd_path}" ]] && [[ -x "${cmd_path}" ]]; then
    ln -sf "${cmd_path}" "${test3_bin}/${cmd}"
  fi
done
# Explicitly do NOT symlink claude

test3_stderr=""
test3_exit=0
test3_stderr=$(echo "${test3_json}" \
  | PATH="${test3_bin}" \
    HOME="/nonexistent_home_$$" \
    CLAUDE_PROJECT_DIR="${test3_dir}/project" \
    HOOK_SESSION_PID="test3_$$" \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || test3_exit=$?

# spawn_fix_subprocess returns 0 when claude is not found (graceful skip).
# The script continues to the verification phase, which exits 2 with
# remaining violations (nothing fixed because no subprocess ran).
assert "test3_exit" "[[ ${test3_exit} -eq 2 ]]" \
  "exit code 2 — verification found remaining violations (${test3_exit})" \
  "exit code ${test3_exit} (expected 2)"

assert "test3_not_found" "echo '${test3_stderr}' | grep -q 'claude binary not found'" \
  "stderr contains 'claude binary not found'" \
  "stderr missing 'claude binary not found'"

assert "test3_violations" "echo '${test3_stderr}' | grep -q 'violation(s) remain'" \
  "stderr contains 'violation(s) remain'" \
  "stderr missing 'violation(s) remain' (verification phase skipped)"

# ============================================================================
# Test 4: subprocess delegation disabled
# ============================================================================
printf "\n--- test4: subprocess delegation disabled ---\n"

test4_dir="${tmp_dir}/test4"
mkdir -p "${test4_dir}/bin"

# Mock claude: writes a marker file if called (should NOT be called)
test4_marker="${test4_dir}/claude_was_called"
cat >"${test4_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
# Mock claude that creates a marker file to prove it was called
touch "${test4_marker}"
exit 0
MOCK_EOF
chmod +x "${test4_dir}/bin/claude"

# Set up project dir with subprocess delegation DISABLED
setup_project_dir "${test4_dir}/project" '{"phases":{"subprocess_delegation":"false"}}'

# Create shell file with violations
test4_file="${test4_dir}/test.sh"
create_bad_shell_file "${test4_file}"

# Build JSON input
test4_json='{"tool_input":{"file_path":"'"${test4_file}"'"}}'

# Run the hook with mock claude on PATH
test4_exit=0
echo "${test4_json}" \
  | PATH="${test4_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test4_dir}/project" \
    HOOK_SESSION_PID="test4_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || test4_exit=$?

assert "test4_exit" "[[ ${test4_exit} -eq 2 ]]" \
  "exit code 2" "exit code ${test4_exit} (expected 2)"

assert "test4_no_call" "[[ ! -f '${test4_marker}' ]]" \
  "mock claude was NOT called" \
  "mock claude was called (marker file exists)"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
