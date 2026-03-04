#!/usr/bin/env bash
# test_security_exclusions_compat.sh - Verifies security_linter_exclusions
# behavior and backward compatibility with the legacy exclusions key.
#
# Usage:
#   bash .claude/tests/hooks/test_security_exclusions_compat.sh

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

if ! command -v jaq >/dev/null 2>&1; then
  printf "SKIP: jaq not installed\n"
  exit 0
fi

isolated_home="${tmp_dir}/home"
mkdir -p "${isolated_home}/.claude"
export HOME="${isolated_home}"

setup_project_dir() {
  local pd="$1"
  local config_content="$2"

  mkdir -p "${pd}/.claude/hooks" "${pd}/bin" "${pd}/tests"

  printf '%s\n' "${config_content}" >"${pd}/.claude/hooks/config.json"

  cat >"${pd}/.claude/subprocess-settings.json" <<'SETTINGS_EOF'
{
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
SETTINGS_EOF

  cat >"${pd}/bin/ruff" <<'MOCK_RUFF'
#!/usr/bin/env bash
if [[ "${1:-}" == "check" ]] && [[ "${2:-}" == "--preview" ]]; then
  echo '[]'
  exit 0
fi
exit 0
MOCK_RUFF
  chmod +x "${pd}/bin/ruff"

  cat >"${pd}/bin/uv" <<'MOCK_UV'
#!/usr/bin/env bash
if [[ "${1:-}" != "run" ]]; then
  exit 0
fi

shift
cmd="${1:-}"
shift || true

case "${cmd}" in
  vulture)
    target="${1:-probe.py}"
    printf '%s:2: unused variable %s\n' "${target}" "'password'"
    ;;
  bandit)
    cat <<'BANDIT_JSON'
{
  "results": [
    {
      "line_number": 2,
      "col_offset": 5,
      "test_id": "B105",
      "issue_text": "Possible hardcoded password"
    }
  ]
}
BANDIT_JSON
    ;;
  ty|flake8)
    ;;
esac

exit 0
MOCK_UV
  chmod +x "${pd}/bin/uv"
}

create_probe_file() {
  local fp="$1"
  cat >"${fp}" <<'PY_EOF'
def get_password():
    password = "secret"
    return password
PY_EOF
}

run_case() {
  local pd="$1"
  local case_name="$2"
  local output_prefix="${tmp_dir}/${case_name}"
  local probe_file="${pd}/tests/probe.py"

  create_probe_file "${probe_file}"

  local exit_code=0
  echo '{"tool_input":{"file_path":"'"${probe_file}"'"}}' \
    | PATH="${pd}/bin:${PATH}" \
      CLAUDE_PROJECT_DIR="${pd}" \
      HOOK_SESSION_PID="${case_name}_$$" \
      HOOK_SKIP_SUBPROCESS=1 \
      bash "${hook_dir}/multi_linter.sh" >"${output_prefix}.stdout" 2>"${output_prefix}.stderr" || exit_code=$?

  printf '%s\n' "${exit_code}" >"${output_prefix}.exit"
}

printf "=== Security Exclusions Compatibility Tests ===\n"

# ============================================================================
# Test 1: legacy exclusions key still suppresses security linters
# ============================================================================
printf "\n--- test1: legacy exclusions fallback still works ---\n"

test1_dir="${tmp_dir}/test1"
setup_project_dir "${test1_dir}" '{
  "phases": { "subprocess_delegation": false },
  "exclusions": ["tests/"]
}'
run_case "${test1_dir}" "test1"

assert "test1_exit" "grep -qx '0' '${tmp_dir}/test1.exit'" \
  "legacy exclusions suppress security linter findings" \
  "legacy exclusions did not suppress security linter findings"

assert "test1_no_b105" "! grep -q 'B105' '${tmp_dir}/test1.stderr'" \
  "legacy exclusions prevent bandit output" \
  "legacy exclusions still emitted bandit output"

# ============================================================================
# Test 2: security_linter_exclusions suppresses security linters
# ============================================================================
printf "\n--- test2: new security_linter_exclusions works ---\n"

test2_dir="${tmp_dir}/test2"
setup_project_dir "${test2_dir}" '{
  "phases": { "subprocess_delegation": false },
  "security_linter_exclusions": ["tests/"]
}'
run_case "${test2_dir}" "test2"

assert "test2_exit" "grep -qx '0' '${tmp_dir}/test2.exit'" \
  "security_linter_exclusions suppress security linter findings" \
  "security_linter_exclusions did not suppress security linter findings"

assert "test2_no_vulture" "! grep -q 'VULTURE' '${tmp_dir}/test2.stderr'" \
  "security_linter_exclusions prevent vulture output" \
  "security_linter_exclusions still emitted vulture output"

# ============================================================================
# Test 3: without exclusions, the same file reports security issues
# ============================================================================
printf "\n--- test3: no exclusions still reports security issues ---\n"

test3_dir="${tmp_dir}/test3"
setup_project_dir "${test3_dir}" '{
  "phases": { "subprocess_delegation": false },
  "security_linter_exclusions": []
}'
run_case "${test3_dir}" "test3"

assert "test3_exit" "grep -qx '2' '${tmp_dir}/test3.exit'" \
  "no exclusions returns exit 2 with remaining violations" \
  "no exclusions did not return exit 2"

assert "test3_b105" "grep -q 'B105' '${tmp_dir}/test3.stderr'" \
  "bandit finding still appears without exclusions" \
  "bandit finding missing without exclusions"

assert "test3_vulture" "grep -q 'VULTURE' '${tmp_dir}/test3.stderr'" \
  "vulture finding still appears without exclusions" \
  "vulture finding missing without exclusions"

printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
