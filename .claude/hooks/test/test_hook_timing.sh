#!/bin/bash
# test_hook_timing.sh - Tests hook_diag() timing observability in multi_linter.sh
#
# Verifies that [hook:timing] lines are emitted for:
# - delegate_plan, delegate_start, delegate_end
# - verify_start, rerun_phase1_start, rerun_phase2_end, verify_end
# - resolved and feedback_loop outcome phases
#
# Also verifies:
# - HOOK_TIMING_LOG_FILE opt-in file logging
# - fail-open when log parent is unwritable
# - tool_name captured from JSON payload (or "unknown" as fallback)
#
# Usage: bash .claude/tests/hooks/test_hook_timing.sh

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

# --- Isolate HOME ---
isolated_home="${tmp_dir}/home"
mkdir -p "${isolated_home}/.claude"
export HOME="${isolated_home}"

# --- Shared mock bin directory ---
mock_bin="${tmp_dir}/mock_bin"
mkdir -p "${mock_bin}"

# --- Mock ruff: standard mode + two-stage mode via MOCK_RUFF_CALL_FILE ---
# Two-stage mode activates only when MOCK_RUFF_CALL_FILE is set:
#   - first --preview call returns MOCK_RUFF_JSON
#   - subsequent --preview calls return MOCK_RUFF_RERUN_JSON (or [])
cat >"${mock_bin}/ruff" <<'RUFF_MOCK'
#!/bin/bash
case "$1" in
  format) exit 0 ;;
  check)
    if [[ "${2:-}" == "--fix" ]]; then exit 0; fi
    if [[ "${2:-}" == "--preview" ]] && [[ "${3:-}" == "--output-format=json" ]]; then
      if [[ -n "${MOCK_RUFF_CALL_FILE:-}" ]]; then
        count=0
        [[ -f "${MOCK_RUFF_CALL_FILE}" ]] && count=$(cat "${MOCK_RUFF_CALL_FILE}")
        echo $((count + 1)) > "${MOCK_RUFF_CALL_FILE}"
        if [[ "${count}" -gt 0 ]] && [[ -n "${MOCK_RUFF_RERUN_JSON:-}" ]]; then
          printf '%s' "${MOCK_RUFF_RERUN_JSON}"
          exit 0
        fi
      fi
      printf '%s' "${MOCK_RUFF_JSON:-[]}"
      exit 0
    fi
    exit 0 ;;
esac
exit 0
RUFF_MOCK
chmod +x "${mock_bin}/ruff"

# --- Mock uv: no-op to prevent ty/flake8-pydantic from running ---
cat >"${mock_bin}/uv" <<'UV_MOCK'
#!/bin/bash
exit 1
UV_MOCK
chmod +x "${mock_bin}/uv"

# --- Helper: create project dir with config ---
setup_project_dir() {
  local pd="$1"
  local config_content="$2"
  mkdir -p "${pd}/.claude/hooks"
  printf '%s\n' "${config_content}" >"${pd}/.claude/hooks/config.json"
  mkdir -p "${pd}/.claude"
  cat >"${pd}/.claude/subprocess-settings.json" <<'SETTINGS_EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
SETTINGS_EOF
}

# --- Helper: create mock claude that exits 0 without modifying file ---
create_mock_claude() {
  local bin_dir="$1"
  local args_file="${2:-/dev/null}"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${args_file}"
exit 0
MOCK_EOF
  chmod +x "${bin_dir}/claude"
}

# --- Config: subprocess delegation ON, cheap haiku tier ---
# Sonnet/opus tier parameters fall back to defaults (max_turns=10, timeout=300/600)
TIER_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": ".*", "tools": "Edit,Read", "max_turns": 1, "timeout": 5}
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 100,
    "settings_file": null
  }
}'

# --- Violation fixture: single D103 (selects sonnet model) ---
SINGLE_D_JSON='[{"code":"D103","message":"Missing docstring in public function","filename":"test.py","location":{"row":1,"column":1},"end_location":{"row":1,"column":1},"fix":null,"url":""}]'

# --- Helper: set up test dir and run hook capturing stderr ---
# Usage: run_hook_with_violations dir json_payload [mock_ruff_json] [extra_env_assignments...]
# env assignments are passed as space-separated KEY=value strings before the bash call
run_hook() {
  local test_dir="$1"
  local json_payload="$2"
  local mock_ruff_json="${3:-${SINGLE_D_JSON}}"

  setup_project_dir "${test_dir}/project" "${TIER_CONFIG}"
  create_mock_claude "${test_dir}/bin" "${test_dir}/args.txt"
  printf 'import os\ndef hello():\n    pass\n' >"${test_dir}/test_file.py"

  echo "${json_payload}" \
    | PATH="${test_dir}/bin:${mock_bin}:${PATH}" \
      CLAUDE_PROJECT_DIR="${test_dir}/project" \
      HOOK_SESSION_PID="timing_$$" \
      MOCK_RUFF_JSON="${mock_ruff_json}" \
      bash "${hook_dir}/multi_linter.sh" >/dev/null 2>"${test_dir}/stderr.txt" || true
}

printf "=== test_hook_timing.sh ===\n"

# ============================================================================
# t1a: [hook:timing] appears in stderr on delegation path
# ============================================================================
printf "\n--- t1a: [hook:timing] in stderr ---\n"

t1a_dir="${tmp_dir}/t1a"
mkdir -p "${t1a_dir}"
t1a_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t1a_dir}/test_file.py"'"}}'
run_hook "${t1a_dir}" "${t1a_json}"

assert "t1a_timing_in_stderr" \
  "grep -q '\[hook:timing\]' '${t1a_dir}/stderr.txt' 2>/dev/null" \
  "[hook:timing] lines appear in stderr" \
  "[hook:timing] NOT found in stderr"

# ============================================================================
# t1b: HOOK_TIMING_LOG_FILE → file created with [hook:timing] content
# ============================================================================
printf "\n--- t1b: HOOK_TIMING_LOG_FILE file logging ---\n"

t1b_dir="${tmp_dir}/t1b"
mkdir -p "${t1b_dir}"
t1b_log="${t1b_dir}/hook_timing.log"
t1b_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t1b_dir}/test_file.py"'"}}'

setup_project_dir "${t1b_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t1b_dir}/bin" "${t1b_dir}/args.txt"
printf 'import os\ndef hello():\n    pass\n' >"${t1b_dir}/test_file.py"

echo "${t1b_json}" \
  | PATH="${t1b_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t1b_dir}/project" \
    HOOK_SESSION_PID="t1b_$$" \
    MOCK_RUFF_JSON="${SINGLE_D_JSON}" \
    HOOK_TIMING_LOG_FILE="${t1b_log}" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>"${t1b_dir}/stderr.txt" || true

assert "t1b_log_created" \
  "[[ -f '${t1b_log}' ]]" \
  "HOOK_TIMING_LOG_FILE created log file" \
  "HOOK_TIMING_LOG_FILE log file NOT created"

assert "t1b_log_has_timing" \
  "grep -q '\[hook:timing\]' '${t1b_log}' 2>/dev/null" \
  "[hook:timing] appears in log file" \
  "[hook:timing] NOT found in log file"

# ============================================================================
# t1c: HOOK_TIMING_LOG_FILE under read-only parent → hook still exits cleanly
# ============================================================================
printf "\n--- t1c: fail-open when log parent unwritable ---\n"

t1c_dir="${tmp_dir}/t1c"
mkdir -p "${t1c_dir}"
t1c_readonly="${t1c_dir}/readonly_parent"
mkdir -p "${t1c_readonly}"
chmod 000 "${t1c_readonly}"

t1c_log="${t1c_readonly}/subdir/hook_timing.log"
t1c_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t1c_dir}/test_file.py"'"}}'

setup_project_dir "${t1c_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t1c_dir}/bin" "${t1c_dir}/args.txt"
printf 'import os\ndef hello():\n    pass\n' >"${t1c_dir}/test_file.py"

t1c_exit=0
echo "${t1c_json}" \
  | PATH="${t1c_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t1c_dir}/project" \
    HOOK_SESSION_PID="t1c_$$" \
    MOCK_RUFF_JSON="${SINGLE_D_JSON}" \
    HOOK_TIMING_LOG_FILE="${t1c_log}" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>/dev/null || t1c_exit=$?

chmod 755 "${t1c_readonly}" # restore for cleanup

assert "t1c_failopen" \
  "[[ '${t1c_exit}' -le 2 ]]" \
  "hook exits 0 or 2 (not crash) when log dir unwritable" \
  "hook crashed with exit=${t1c_exit} when log dir unwritable"

# ============================================================================
# t2a: tool=unknown when .tool_name absent from JSON payload
# ============================================================================
printf "\n--- t2a: tool=unknown when tool_name absent ---\n"

t2a_dir="${tmp_dir}/t2a"
mkdir -p "${t2a_dir}"
t2a_json='{"tool_input":{"file_path":"'"${t2a_dir}/test_file.py"'"}}'
run_hook "${t2a_dir}" "${t2a_json}"

assert "t2a_tool_unknown" \
  "grep -q 'tool=unknown' '${t2a_dir}/stderr.txt' 2>/dev/null" \
  "tool=unknown when tool_name absent from payload" \
  "tool=unknown NOT found in stderr"

# ============================================================================
# t2b: tool_name captured from payload
# ============================================================================
printf "\n--- t2b: tool=Write captured from payload ---\n"

t2b_dir="${tmp_dir}/t2b"
mkdir -p "${t2b_dir}"
t2b_json='{"tool_name":"Write","tool_input":{"file_path":"'"${t2b_dir}/test_file.py"'"}}'
run_hook "${t2b_dir}" "${t2b_json}"

assert "t2b_tool_write" \
  "grep -q 'tool=Write' '${t2b_dir}/stderr.txt' 2>/dev/null" \
  "tool=Write captured from JSON payload" \
  "tool=Write NOT found in stderr"

# ============================================================================
# t3a: phase=delegate_plan appears in stderr
# ============================================================================
printf "\n--- t3a: phase=delegate_plan ---\n"

t3a_dir="${tmp_dir}/t3a"
mkdir -p "${t3a_dir}"
t3a_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t3a_dir}/test_file.py"'"}}'
run_hook "${t3a_dir}" "${t3a_json}"

assert "t3a_delegate_plan" \
  "grep -q 'phase=delegate_plan' '${t3a_dir}/stderr.txt' 2>/dev/null" \
  "phase=delegate_plan appears in stderr" \
  "phase=delegate_plan NOT found in stderr"

# ============================================================================
# t3b: phase=delegate_start with count=1 (1 D103 violation)
# ============================================================================
printf "\n--- t3b: phase=delegate_start with count=1 ---\n"

t3b_dir="${tmp_dir}/t3b"
mkdir -p "${t3b_dir}"
t3b_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t3b_dir}/test_file.py"'"}}'
run_hook "${t3b_dir}" "${t3b_json}"

assert "t3b_delegate_start" \
  "grep -q 'phase=delegate_start' '${t3b_dir}/stderr.txt' 2>/dev/null" \
  "phase=delegate_start appears in stderr" \
  "phase=delegate_start NOT found in stderr"

assert "t3b_count_1" \
  "grep 'phase=delegate_start' '${t3b_dir}/stderr.txt' 2>/dev/null | grep -q 'count=1'" \
  "delegate_start has count=1" \
  "delegate_start does NOT have count=1"

# ============================================================================
# t3c: phase=delegate_end with changed=no (mock claude does not modify file)
# ============================================================================
printf "\n--- t3c: phase=delegate_end with changed=no ---\n"

t3c_dir="${tmp_dir}/t3c"
mkdir -p "${t3c_dir}"
t3c_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t3c_dir}/test_file.py"'"}}'
run_hook "${t3c_dir}" "${t3c_json}"

assert "t3c_delegate_end" \
  "grep -q 'phase=delegate_end' '${t3c_dir}/stderr.txt' 2>/dev/null" \
  "phase=delegate_end appears in stderr" \
  "phase=delegate_end NOT found in stderr"

assert "t3c_changed_no" \
  "grep 'phase=delegate_end' '${t3c_dir}/stderr.txt' 2>/dev/null | grep -q 'changed=no'" \
  "delegate_end has changed=no (mock claude did not modify file)" \
  "delegate_end does NOT have changed=no"

# ============================================================================
# t4a: phase=verify_start appears in stderr
# ============================================================================
printf "\n--- t4a: phase=verify_start ---\n"

t4a_dir="${tmp_dir}/t4a"
mkdir -p "${t4a_dir}"
t4a_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t4a_dir}/test_file.py"'"}}'
run_hook "${t4a_dir}" "${t4a_json}"

assert "t4a_verify_start" \
  "grep -q 'phase=verify_start' '${t4a_dir}/stderr.txt' 2>/dev/null" \
  "phase=verify_start appears in stderr" \
  "phase=verify_start NOT found in stderr"

# ============================================================================
# t4b: phase=rerun_phase1_start appears in stderr
# ============================================================================
printf "\n--- t4b: phase=rerun_phase1_start ---\n"

t4b_dir="${tmp_dir}/t4b"
mkdir -p "${t4b_dir}"
t4b_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t4b_dir}/test_file.py"'"}}'
run_hook "${t4b_dir}" "${t4b_json}"

assert "t4b_phase1_start" \
  "grep -q 'phase=rerun_phase1_start' '${t4b_dir}/stderr.txt' 2>/dev/null" \
  "phase=rerun_phase1_start appears in stderr" \
  "phase=rerun_phase1_start NOT found in stderr"

# ============================================================================
# t4c: phase=rerun_phase2_end with remaining_count= field
# ============================================================================
printf "\n--- t4c: phase=rerun_phase2_end with remaining_count ---\n"

t4c_dir="${tmp_dir}/t4c"
mkdir -p "${t4c_dir}"
t4c_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t4c_dir}/test_file.py"'"}}'
run_hook "${t4c_dir}" "${t4c_json}"

assert "t4c_phase2_end" \
  "grep -q 'phase=rerun_phase2_end' '${t4c_dir}/stderr.txt' 2>/dev/null" \
  "phase=rerun_phase2_end appears in stderr" \
  "phase=rerun_phase2_end NOT found in stderr"

assert "t4c_remaining_count" \
  "grep 'phase=rerun_phase2_end' '${t4c_dir}/stderr.txt' 2>/dev/null | grep -q 'remaining_count='" \
  "rerun_phase2_end has remaining_count= field" \
  "rerun_phase2_end does NOT have remaining_count= field"

# ============================================================================
# t4d: phase=verify_end with duration_s= field
# ============================================================================
printf "\n--- t4d: phase=verify_end with duration_s ---\n"

t4d_dir="${tmp_dir}/t4d"
mkdir -p "${t4d_dir}"
t4d_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t4d_dir}/test_file.py"'"}}'
run_hook "${t4d_dir}" "${t4d_json}"

assert "t4d_verify_end" \
  "grep -q 'phase=verify_end' '${t4d_dir}/stderr.txt' 2>/dev/null" \
  "phase=verify_end appears in stderr" \
  "phase=verify_end NOT found in stderr"

assert "t4d_duration_s" \
  "grep 'phase=verify_end' '${t4d_dir}/stderr.txt' 2>/dev/null | grep -q 'duration_s='" \
  "verify_end has duration_s= field" \
  "verify_end does NOT have duration_s= field"

# ============================================================================
# t5a: phase=resolved when rerun returns [] (two-stage mock ruff)
# ============================================================================
printf "\n--- t5a: phase=resolved when rerun returns 0 violations ---\n"

t5a_dir="${tmp_dir}/t5a"
mkdir -p "${t5a_dir}"
t5a_call_file="${tmp_dir}/t5a_ruff_calls"
t5a_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t5a_dir}/test_file.py"'"}}'

setup_project_dir "${t5a_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t5a_dir}/bin" "${t5a_dir}/args.txt"
printf 'import os\ndef hello():\n    pass\n' >"${t5a_dir}/test_file.py"

echo "${t5a_json}" \
  | PATH="${t5a_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t5a_dir}/project" \
    HOOK_SESSION_PID="t5a_$$" \
    MOCK_RUFF_JSON="${SINGLE_D_JSON}" \
    MOCK_RUFF_RERUN_JSON="[]" \
    MOCK_RUFF_CALL_FILE="${t5a_call_file}" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>"${t5a_dir}/stderr.txt" || true

assert "t5a_resolved" \
  "grep -q 'phase=resolved' '${t5a_dir}/stderr.txt' 2>/dev/null" \
  "phase=resolved logged when rerun returns 0 violations" \
  "phase=resolved NOT found in stderr"

# ============================================================================
# t5b: phase=feedback_loop when violations persist after delegation
# ============================================================================
printf "\n--- t5b: phase=feedback_loop when violations persist ---\n"

t5b_dir="${tmp_dir}/t5b"
mkdir -p "${t5b_dir}"
t5b_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t5b_dir}/test_file.py"'"}}'
run_hook "${t5b_dir}" "${t5b_json}"

assert "t5b_feedback_loop" \
  "grep -q 'phase=feedback_loop' '${t5b_dir}/stderr.txt' 2>/dev/null" \
  "phase=feedback_loop logged when violations persist after delegation" \
  "phase=feedback_loop NOT found in stderr"

# D103 + unresolved-attribute: unfiltered→opus, D-filtered→sonnet
MIXED_D_OPUS_JSON_TIMING='[{"code":"D103","message":"Missing docstring","filename":"test.py","location":{"row":4,"column":1},"end_location":{"row":4,"column":10},"fix":null,"url":""},{"code":"unresolved-attribute","message":"Cannot access attribute","filename":"test.py","location":{"row":5,"column":1},"end_location":{"row":5,"column":10},"fix":null,"url":""}]'

# ============================================================================
# t6a: [hook:model] emitted when HOOK_DEBUG_MODEL=1
# ============================================================================
printf "\n--- t6a: [hook:model] emitted when HOOK_DEBUG_MODEL=1 ---\n"

t6a_dir="${tmp_dir}/t6a"
mkdir -p "${t6a_dir}"
t6a_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t6a_dir}/test_file.py"'"}}'

setup_project_dir "${t6a_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t6a_dir}/bin" "${t6a_dir}/args.txt"
printf 'import os\ndef hello():\n    pass\n' >"${t6a_dir}/test_file.py"

echo "${t6a_json}" \
  | PATH="${t6a_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t6a_dir}/project" \
    HOOK_SESSION_PID="t6a_$$" \
    MOCK_RUFF_JSON="${SINGLE_D_JSON}" \
    HOOK_DEBUG_MODEL="1" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>"${t6a_dir}/stderr.txt" || true

assert "t6a_hook_model_present" \
  "grep -q '\[hook:model\]' '${t6a_dir}/stderr.txt'" \
  "[hook:model] line appears in stderr when HOOK_DEBUG_MODEL=1" \
  "[hook:model] line is missing from stderr"

# ============================================================================
# t6b: [hook:model] uses D-only filtered model (not opus from unresolved-attribute)
# ============================================================================
printf "\n--- t6b: [hook:model] uses D-filtered model (not opus from unresolved-attribute) ---\n"

t6b_dir="${tmp_dir}/t6b"
mkdir -p "${t6b_dir}"
t6b_json='{"tool_name":"Edit","tool_input":{"file_path":"'"${t6b_dir}/test_file.py"'"}}'

setup_project_dir "${t6b_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t6b_dir}/bin" "${t6b_dir}/args.txt"
printf 'import os\ndef hello():\n    pass\n' >"${t6b_dir}/test_file.py"

echo "${t6b_json}" \
  | PATH="${t6b_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t6b_dir}/project" \
    HOOK_SESSION_PID="t6b_$$" \
    MOCK_RUFF_JSON="${MIXED_D_OPUS_JSON_TIMING}" \
    HOOK_DEBUG_MODEL="1" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>"${t6b_dir}/stderr.txt" || true

assert "t6b_model_sonnet" \
  "grep -q '\[hook:model\] sonnet' '${t6b_dir}/stderr.txt' 2>/dev/null" \
  "[hook:model] says sonnet for D103+unresolved-attribute (D-filtered)" \
  "[hook:model] does NOT say sonnet after D-filtering"

assert "t6b_not_opus" \
  "! grep -q '\[hook:model\] opus' '${t6b_dir}/stderr.txt' 2>/dev/null" \
  "[hook:model] not opus after filtering out unresolved-attribute" \
  "[hook:model] incorrectly says opus (unfiltered set)"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
