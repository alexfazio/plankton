#!/bin/bash
# test_subprocess_permissions.sh - Tests subprocess permission and tool flags
#
# Verifies that:
# - --dangerously-skip-permissions is always passed
# - --disallowedTools is used instead of --allowedTools
# - Safety invariant: skip-permissions never appears without disallowedTools
# - AskUserQuestion / plan-mode tools are explicitly blacklisted for subprocesses
#
# Usage: bash .claude/tests/hooks/test_subprocess_permissions.sh

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
  # shellcheck disable=SC2016  # intentional: test fixture with literal $y
  printf '#!/bin/bash\nunused="x"\necho $y\n' >"${fp}"
}

# === Begin tests ===
printf "=== Subprocess Permission Tests ===\n"

# ============================================================================
# Test 1a: --dangerously-skip-permissions is always passed
# ============================================================================
printf "\n--- test1a: --dangerously-skip-permissions is passed ---\n"

test1a_dir="${tmp_dir}/test1a"
mkdir -p "${test1a_dir}/bin"

# Mock claude that logs all args to a file
test1a_args="${test1a_dir}/claude_args.txt"
cat >"${test1a_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${test1a_args}"
exit 0
MOCK_EOF
chmod +x "${test1a_dir}/bin/claude"

setup_project_dir "${test1a_dir}/project" '{"phases":{"subprocess_delegation":true}}'

test1a_file="${test1a_dir}/test.sh"
create_bad_shell_file "${test1a_file}"

test1a_json='{"tool_input":{"file_path":"'"${test1a_file}"'"}}'

export test1a_exit=0
echo "${test1a_json}" \
  | PATH="${test1a_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test1a_dir}/project" \
    HOOK_SESSION_PID="test1a_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || test1a_exit=$?

assert "test1a_skip_perms" \
  "grep -q -- '--dangerously-skip-permissions' '${test1a_args}'" \
  "--dangerously-skip-permissions present" \
  "--dangerously-skip-permissions MISSING from subprocess args"

# ============================================================================
# Test 1b: --disallowedTools used, --allowedTools absent
# ============================================================================
printf "\n--- test1b: --disallowedTools used, --allowedTools absent ---\n"

assert "test1b_disallowed" \
  "grep -q -- '--disallowedTools' '${test1a_args}'" \
  "--disallowedTools present" \
  "--disallowedTools MISSING from subprocess args"

assert "test1b_no_allowed" \
  "! grep -q -- '--allowedTools' '${test1a_args}'" \
  "--allowedTools absent (correct)" \
  "--allowedTools still present (should be replaced by --disallowedTools)"

# ============================================================================
# Test 1b2: newer interactive tools are explicitly blacklisted
# ============================================================================
printf "\n--- test1b2: AskUserQuestion and plan-mode tools are blocked ---\n"

assert "test1b2_ask_user_question" \
  "grep -q 'AskUserQuestion' '${test1a_args}'" \
  "AskUserQuestion present in disallowed tool list" \
  "AskUserQuestion missing from disallowed tool list"

assert "test1b2_enter_plan_mode" \
  "grep -q 'EnterPlanMode' '${test1a_args}'" \
  "EnterPlanMode present in disallowed tool list" \
  "EnterPlanMode missing from disallowed tool list"

assert "test1b2_exit_plan_mode" \
  "grep -q 'ExitPlanMode' '${test1a_args}'" \
  "ExitPlanMode present in disallowed tool list" \
  "ExitPlanMode missing from disallowed tool list"

# ============================================================================
# Test 1c: safety invariant — skip-permissions never without disallowedTools
# ============================================================================
printf "\n--- test1c: safety invariant ---\n"

# If --dangerously-skip-permissions is present, --disallowedTools must also be
test1c_has_skip="false"
test1c_has_disallowed="false"
if grep -q -- '--dangerously-skip-permissions' "${test1a_args}" 2>/dev/null; then
  test1c_has_skip="true"
fi
if grep -q -- '--disallowedTools' "${test1a_args}" 2>/dev/null; then
  test1c_has_disallowed="true"
fi

assert "test1c_invariant" \
  "[[ '${test1c_has_skip}' != 'true' ]] || [[ '${test1c_has_disallowed}' == 'true' ]]" \
  "skip-permissions implies disallowedTools" \
  "SAFETY VIOLATION: --dangerously-skip-permissions without --disallowedTools"

# ============================================================================
# Test 1d: CLAUDECODE env var is unset before subprocess invocation
# ============================================================================
printf "\n--- test1d: env -u CLAUDECODE present in subprocess invocation ---\n"

# Mock claude that logs its environment to a file
test1d_dir="${tmp_dir}/test1d"
mkdir -p "${test1d_dir}/bin"

test1d_env="${test1d_dir}/claude_env.txt"
cat >"${test1d_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
env > "${test1d_env}"
printf '%s\n' "\$@" >> "${test1d_env}"
exit 0
MOCK_EOF
chmod +x "${test1d_dir}/bin/claude"

setup_project_dir "${test1d_dir}/project" '{"phases":{"subprocess_delegation":true}}'

test1d_file="${test1d_dir}/test.sh"
create_bad_shell_file "${test1d_file}"

test1d_json='{"tool_input":{"file_path":"'"${test1d_file}"'"}}'

export CLAUDECODE=1 # simulate being inside CC session
export test1d_exit=0
echo "${test1d_json}" \
  | PATH="${test1d_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test1d_dir}/project" \
    HOOK_SESSION_PID="test1d_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || test1d_exit=$?
unset CLAUDECODE

assert "test1d_claudecode_unset" \
  "! grep -q '^CLAUDECODE=' '${test1d_env}'" \
  "CLAUDECODE is NOT in subprocess env (correct)" \
  "CLAUDECODE still present in subprocess env (bug: env -u CLAUDECODE missing)"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
