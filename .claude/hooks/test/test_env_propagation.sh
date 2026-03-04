#!/usr/bin/env bash
# test_env_propagation.sh — Tests environment variable propagation to Phase 3 subprocess
#
# Verifies:
# - 2a: ANTHROPIC_BASE_URL (and other non-CLAUDECODE env vars) set in the hook's
#       shell environment ARE inherited by the Phase 3 subprocess (claude -p)
# - 2b: CLAUDECODE is NOT inherited (env -u CLAUDECODE strips it)
#        [complements test1d in test_subprocess_permissions.sh]
#
# Background: Claude Code injects `env` block values from --settings into its own
# Node.js process environment. Since hook bash scripts are child processes of CC,
# they inherit these vars. The Phase 3 subprocess further inherits from the hook
# (minus CLAUDECODE). This test confirms the hook→subprocess leg of that chain.
#
# Usage: bash .claude/tests/hooks/test_env_propagation.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_dir="$(cd "${script_dir}/../../hooks" && pwd)"

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

passed=0
failed=0

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

# --- Gate: shellcheck required (hook processes shell files) ---
if ! command -v shellcheck >/dev/null 2>&1; then
  printf "SKIP: shellcheck not installed\n"
  exit 0
fi

# --- Isolate HOME ---
isolated_home="${tmp_dir}/home"
mkdir -p "${isolated_home}/.claude"
export HOME="${isolated_home}"

# --- Helpers (mirrored from test_subprocess_permissions.sh) ---
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

create_bad_shell_file() {
  local fp="$1"
  # shellcheck disable=SC2016  # intentional: test fixture with literal $y
  printf '#!/bin/bash\nunused="x"\necho $y\n' >"${fp}"
}

printf "=== Environment Propagation Tests ===\n"

# ============================================================================
# Test 2a: ANTHROPIC_BASE_URL propagates from hook env to subprocess env
# ============================================================================
printf "\n--- test_2a: ANTHROPIC_BASE_URL present in subprocess env ---\n"

test2a_dir="${tmp_dir}/test2a"
mkdir -p "${test2a_dir}/bin"

test2a_env="${test2a_dir}/claude_env.txt"
cat >"${test2a_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
env > "${test2a_env}"
printf '%s\n' "\$@" >> "${test2a_env}"
exit 0
MOCK_EOF
chmod +x "${test2a_dir}/bin/claude"

setup_project_dir "${test2a_dir}/project" '{"phases":{"subprocess_delegation":true}}'

test2a_file="${test2a_dir}/test.sh"
create_bad_shell_file "${test2a_file}"

test2a_json='{"tool_input":{"file_path":"'"${test2a_file}"'"}}'

export ANTHROPIC_BASE_URL="https://test.example.com"
export test2a_exit=0
echo "${test2a_json}" \
  | PATH="${test2a_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test2a_dir}/project" \
    HOOK_SESSION_PID="test2a_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || test2a_exit=$?
unset ANTHROPIC_BASE_URL

assert "test_2a_url_propagated" \
  "grep -q '^ANTHROPIC_BASE_URL=https://test.example.com$' '${test2a_env}'" \
  "ANTHROPIC_BASE_URL propagated to subprocess env (correct)" \
  "ANTHROPIC_BASE_URL missing from subprocess env (env -u strips too much)"

# ============================================================================
# Test 2b: CLAUDECODE is still NOT propagated (regression guard for test1d)
# ============================================================================
printf "\n--- test_2b: CLAUDECODE still absent from subprocess env ---\n"

# Reuse the same env dump from test2a (same invocation had CLAUDECODE unset)
# Run a fresh invocation with CLAUDECODE=1 to confirm it's stripped
test2b_dir="${tmp_dir}/test2b"
mkdir -p "${test2b_dir}/bin"

test2b_env="${test2b_dir}/claude_env.txt"
cat >"${test2b_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
env > "${test2b_env}"
printf '%s\n' "\$@" >> "${test2b_env}"
exit 0
MOCK_EOF
chmod +x "${test2b_dir}/bin/claude"

setup_project_dir "${test2b_dir}/project" '{"phases":{"subprocess_delegation":true}}'

test2b_file="${test2b_dir}/test.sh"
create_bad_shell_file "${test2b_file}"

test2b_json='{"tool_input":{"file_path":"'"${test2b_file}"'"}}'

export CLAUDECODE=1
export ANTHROPIC_BASE_URL="https://test.example.com"
export test2b_exit=0
echo "${test2b_json}" \
  | PATH="${test2b_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${test2b_dir}/project" \
    HOOK_SESSION_PID="test2b_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || test2b_exit=$?
unset CLAUDECODE
unset ANTHROPIC_BASE_URL

assert "test_2b_claudecode_absent" \
  "! grep -q '^CLAUDECODE=' '${test2b_env}'" \
  "CLAUDECODE absent from subprocess env when ANTHROPIC_BASE_URL also set (correct)" \
  "CLAUDECODE present in subprocess env (env -u CLAUDECODE not working)"

assert "test_2b_url_still_propagated" \
  "grep -q '^ANTHROPIC_BASE_URL=https://test.example.com$' '${test2b_env}'" \
  "ANTHROPIC_BASE_URL still propagated alongside CLAUDECODE unset (correct)" \
  "ANTHROPIC_BASE_URL missing (env -u may be stripping too aggressively)"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
