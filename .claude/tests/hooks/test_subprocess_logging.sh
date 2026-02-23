#!/bin/bash
# test_subprocess_logging.sh - Tests subprocess diagnostic logging
#
# Verifies that:
# - Subprocess stderr flows through to hook stderr
# - File modification is detected and logged
# - Model and tool scope are logged
#
# Usage: bash .claude/tests/hooks/test_subprocess_logging.sh

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

# --- Gate: shellcheck required ---
if ! command -v shellcheck >/dev/null 2>&1; then
  printf "SKIP: shellcheck not installed\n"
  exit 0
fi

# --- Isolate HOME ---
isolated_home="${tmp_dir}/home"
mkdir -p "${isolated_home}/.claude"
export HOME="${isolated_home}"

# --- Helper: create project dir with config ---
setup_project_dir() {
  local pd="$1"
  local config_content="$2"
  mkdir -p "${pd}/.claude/hooks"
  printf '%s\n' "${config_content}" >"${pd}/.claude/hooks/config.json"
  cat >"${pd}/.claude/subprocess-settings.json" <<'SETTINGS_EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
SETTINGS_EOF
}

# --- Helper: create shell file with ShellCheck violations ---
create_bad_shell_file() {
  local fp="$1"
  printf "#!/bin/bash\nunused=\"x\"\necho \$y\n" >"${fp}"
}

# === Begin tests ===
printf "=== Subprocess Logging Tests ===\n"

# ============================================================================
# Test 3a: subprocess stderr flows to hook stderr
# ============================================================================
printf "\n--- test3a: subprocess stderr flows to hook stderr ---\n"

test3a_dir="${tmp_dir}/test3a"
mkdir -p "${test3a_dir}/bin"

# Mock claude that writes diagnostic output to stderr
cat >"${test3a_dir}/bin/claude" <<'MOCK_EOF'
#!/bin/bash
echo "SUBPROCESS_STDERR_MARKER" >&2
exit 0
MOCK_EOF
chmod +x "${test3a_dir}/bin/claude"

setup_project_dir "${test3a_dir}/project" '{"phases":{"subprocess_delegation":true}}'

test3a_file="${test3a_dir}/test.sh"
create_bad_shell_file "${test3a_file}"

test3a_json='{"tool_input":{"file_path":"'"${test3a_file}"'"}}'

test3a_stderr=""
export test3a_exit=0
test3a_stderr=$(echo "${test3a_json}" \
  | PATH="${test3a_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test3a_dir}/project" \
    HOOK_SESSION_PID="test3a_$$" \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || test3a_exit=$?

assert "test3a_stderr_flows" \
  "echo '${test3a_stderr}' | grep -q 'SUBPROCESS_STDERR_MARKER'" \
  "subprocess stderr visible in hook stderr" \
  "subprocess stderr NOT visible (still redirected to /dev/null)"

# ============================================================================
# Test 3b: log whether file was modified
# ============================================================================
printf "\n--- test3b: log file modification status ---\n"

# 3b-modified: mock claude that modifies the file
test3b_dir="${tmp_dir}/test3b"
mkdir -p "${test3b_dir}/bin"

cat >"${test3b_dir}/bin/claude" <<'MOCK_EOF'
#!/bin/bash
# Find file path from last arg and modify it
target_file="${!#}"
if [[ -f "${target_file}" ]]; then
  printf '#!/bin/bash\necho "clean"\n' > "${target_file}"
fi
exit 0
MOCK_EOF
chmod +x "${test3b_dir}/bin/claude"

setup_project_dir "${test3b_dir}/project" '{"phases":{"subprocess_delegation":true}}'

test3b_file="${test3b_dir}/test.sh"
create_bad_shell_file "${test3b_file}"

test3b_json='{"tool_input":{"file_path":"'"${test3b_file}"'"}}'

test3b_stderr=""
export test3b_exit=0
test3b_stderr=$(echo "${test3b_json}" \
  | PATH="${test3b_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test3b_dir}/project" \
    HOOK_SESSION_PID="test3b_$$" \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || test3b_exit=$?

assert "test3b_modified" \
  "echo '${test3b_stderr}' | grep -q 'file modified'" \
  "stderr says file modified" \
  "stderr missing 'file modified' marker"

# 3b-unmodified: mock claude that does nothing
test3b2_dir="${tmp_dir}/test3b2"
mkdir -p "${test3b2_dir}/bin"

cat >"${test3b2_dir}/bin/claude" <<'MOCK_EOF'
#!/bin/bash
exit 0
MOCK_EOF
chmod +x "${test3b2_dir}/bin/claude"

setup_project_dir "${test3b2_dir}/project" '{"phases":{"subprocess_delegation":true}}'

test3b2_file="${test3b2_dir}/test.sh"
create_bad_shell_file "${test3b2_file}"

test3b2_json='{"tool_input":{"file_path":"'"${test3b2_file}"'"}}'

test3b2_stderr=""
export test3b2_exit=0
test3b2_stderr=$(echo "${test3b2_json}" \
  | PATH="${test3b2_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test3b2_dir}/project" \
    HOOK_SESSION_PID="test3b2_$$" \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || test3b2_exit=$?

assert "test3b_unmodified" \
  "echo '${test3b2_stderr}' | grep -q 'file unchanged'" \
  "stderr says file unchanged" \
  "stderr missing 'file unchanged' marker"

# ============================================================================
# Test 3c: log subprocess model and tool scope
# ============================================================================
printf "\n--- test3c: log model and tool scope ---\n"

test3c_dir="${tmp_dir}/test3c"
mkdir -p "${test3c_dir}/bin"

cat >"${test3c_dir}/bin/claude" <<'MOCK_EOF'
#!/bin/bash
exit 0
MOCK_EOF
chmod +x "${test3c_dir}/bin/claude"

setup_project_dir "${test3c_dir}/project" '{"phases":{"subprocess_delegation":true}}'

test3c_file="${test3c_dir}/test.sh"
create_bad_shell_file "${test3c_file}"

test3c_json='{"tool_input":{"file_path":"'"${test3c_file}"'"}}'

test3c_stderr=""
export test3c_exit=0
test3c_stderr=$(echo "${test3c_json}" \
  | PATH="${test3c_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test3c_dir}/project" \
    HOOK_SESSION_PID="test3c_$$" \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || test3c_exit=$?

assert "test3c_model_logged" \
  "echo '${test3c_stderr}' | grep -q '\\[hook:subprocess\\].*model='" \
  "stderr contains [hook:subprocess] with model" \
  "stderr missing model info in subprocess log"

assert "test3c_tools_logged" \
  "echo '${test3c_stderr}' | grep -q '\\[hook:subprocess\\].*tools='" \
  "stderr contains [hook:subprocess] with tools" \
  "stderr missing tools info in subprocess log"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
