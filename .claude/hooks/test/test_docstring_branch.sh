#!/bin/bash
# test_docstring_branch.sh - Tests BUG-7: mixed Python violations stall subprocess
#
# Verifies that:
# - D-only violations route to docstring-specific prompt
# - Mixed D + non-D violations filter to D-only in docstring prompt
# - DTZ/DL codes do NOT trigger docstring branch
# - Prompts do not contain Bash-dependent instructions (ruff format, ruff check)
#
# Uses mocked ruff + mocked claude for deterministic output.
#
# Usage: bash .claude/tests/hooks/test_docstring_branch.sh

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

# --- Mock ruff: reads MOCK_RUFF_JSON env var for check --output-format=json ---
cat >"${mock_bin}/ruff" <<'RUFF_MOCK'
#!/bin/bash
# Mock ruff: format=no-op, check --fix=no-op, check --output-format=json=emit MOCK_RUFF_JSON
case "$1" in
  format) exit 0 ;;
  check)
    # check --fix → no-op
    if [[ "${2:-}" == "--fix" ]]; then exit 0; fi
    # check --preview --output-format=json → emit controlled JSON
    if [[ "${2:-}" == "--preview" ]] && [[ "${3:-}" == "--output-format=json" ]]; then
      printf '%s' "${MOCK_RUFF_JSON:-[]}"
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
RUFF_MOCK
chmod +x "${mock_bin}/ruff"

# --- Mock uv: no-op to prevent ty from running ---
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

# --- Helper: create mock claude that captures prompt ---
create_mock_claude() {
  local bin_dir="$1"
  local prompt_file="$2"
  local args_file="$3"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${args_file}"
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -p) shift; printf '%s' "\$1" > "${prompt_file}"; shift ;;
    *) shift ;;
  esac
done
exit 0
MOCK_EOF
  chmod +x "${bin_dir}/claude"
}

# --- Config: subprocess delegation ON ---
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

# --- Pre-built violation JSONs for mock ruff ---
# D103 only (docstring violation)
D_ONLY_JSON='[{"code":"D103","message":"Missing docstring in public function","location":{"row":4,"column":1},"end_location":{"row":4,"column":10},"fix":null,"filename":"test.py","noqa_row":4,"url":"https://docs.astral.sh/ruff/rules/undocumented-public-function"}]'

# Mixed: D103 + F401 (docstring + unused import)
MIXED_D_F_JSON='[{"code":"D103","message":"Missing docstring in public function","location":{"row":4,"column":1},"end_location":{"row":4,"column":10},"fix":null,"filename":"test.py","noqa_row":4,"url":"https://docs.astral.sh/ruff/rules/undocumented-public-function"},{"code":"F401","message":"os imported but unused","location":{"row":1,"column":8},"end_location":{"row":1,"column":10},"fix":{"applicability":"safe","message":"Remove unused import: os","edits":[]},"filename":"test.py","noqa_row":1,"url":"https://docs.astral.sh/ruff/rules/unused-import"}]'

# DTZ005 only (datetime without tz — starts with D but NOT a docstring code)
DTZ_ONLY_JSON='[{"code":"DTZ005","message":"datetime.datetime.now() called without a tz argument","location":{"row":5,"column":5},"end_location":{"row":5,"column":26},"fix":null,"filename":"test.py","noqa_row":5,"url":"https://docs.astral.sh/ruff/rules/call-datetime-now-without-tzinfo"}]'

# F401 only (no docstring violations)
F_ONLY_JSON='[{"code":"F401","message":"os imported but unused","location":{"row":1,"column":8},"end_location":{"row":1,"column":10},"fix":{"applicability":"safe","message":"Remove unused import: os","edits":[]},"filename":"test.py","noqa_row":1,"url":"https://docs.astral.sh/ruff/rules/unused-import"}]'

# === Begin tests ===
printf "=== BUG-7: Docstring Branch Tests ===\n"

# ============================================================================
# Test 7a: D-only violations route to docstring branch
# ============================================================================
printf "\n--- test7a: D-only violations use docstring prompt ---\n"

t7a_dir="${tmp_dir}/t7a"
setup_project_dir "${t7a_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t7a_dir}/bin" "${t7a_dir}/prompt.txt" "${t7a_dir}/args.txt"

# Create a Python file (content doesn't matter — mock ruff controls violations)
printf 'def hello():\n    pass\n' >"${t7a_dir}/test_file.py"

t7a_json='{"tool_input":{"file_path":"'"${t7a_dir}/test_file.py"'"}}'

export t7a_exit=0
echo "${t7a_json}" \
  | PATH="${t7a_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t7a_dir}/project" \
    HOOK_SESSION_PID="t7a_$$" \
    MOCK_RUFF_JSON="${D_ONLY_JSON}" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || t7a_exit=$?

assert "t7a_docstring_prompt" \
  "grep -q 'docstring fixer' '${t7a_dir}/prompt.txt' 2>/dev/null" \
  "D-only violations use docstring fixer prompt" \
  "D-only violations did NOT use docstring fixer prompt"

assert "t7a_has_D103" \
  "grep -q 'D103' '${t7a_dir}/prompt.txt' 2>/dev/null" \
  "prompt contains D103 violation" \
  "prompt missing D103"

# ============================================================================
# Test 7b: Mixed D + non-D violations filter to D-only in prompt
# ============================================================================
printf "\n--- test7b: mixed violations filter to D-only in prompt ---\n"

t7b_dir="${tmp_dir}/t7b"
setup_project_dir "${t7b_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t7b_dir}/bin" "${t7b_dir}/prompt.txt" "${t7b_dir}/args.txt"

printf 'import os\ndef hello():\n    pass\n' >"${t7b_dir}/test_file.py"

t7b_json='{"tool_input":{"file_path":"'"${t7b_dir}/test_file.py"'"}}'

export t7b_exit=0
echo "${t7b_json}" \
  | PATH="${t7b_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t7b_dir}/project" \
    HOOK_SESSION_PID="t7b_$$" \
    MOCK_RUFF_JSON="${MIXED_D_F_JSON}" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || t7b_exit=$?

assert "t7b_docstring_prompt" \
  "grep -q 'docstring fixer' '${t7b_dir}/prompt.txt' 2>/dev/null" \
  "mixed violations still use docstring fixer prompt" \
  "mixed violations did NOT use docstring fixer prompt"

assert "t7b_no_F401" \
  "! grep -q 'F401' '${t7b_dir}/prompt.txt' 2>/dev/null" \
  "docstring prompt does NOT contain F401" \
  "docstring prompt CONTAINS F401 (should be filtered out)"

assert "t7b_has_D103" \
  "grep -q 'D103' '${t7b_dir}/prompt.txt' 2>/dev/null" \
  "docstring prompt contains D103" \
  "docstring prompt missing D103"

# ============================================================================
# Test 7d: DTZ codes do NOT trigger docstring branch
# ============================================================================
printf "\n--- test7d: DTZ codes use generic prompt ---\n"

t7d_dir="${tmp_dir}/t7d"
setup_project_dir "${t7d_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t7d_dir}/bin" "${t7d_dir}/prompt.txt" "${t7d_dir}/args.txt"

printf 'import datetime\nx = datetime.datetime.now()\n' >"${t7d_dir}/test_file.py"

t7d_json='{"tool_input":{"file_path":"'"${t7d_dir}/test_file.py"'"}}'

export t7d_exit=0
echo "${t7d_json}" \
  | PATH="${t7d_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t7d_dir}/project" \
    HOOK_SESSION_PID="t7d_$$" \
    MOCK_RUFF_JSON="${DTZ_ONLY_JSON}" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || t7d_exit=$?

assert "t7d_not_docstring" \
  "! grep -q 'docstring fixer' '${t7d_dir}/prompt.txt' 2>/dev/null" \
  "DTZ codes do NOT use docstring fixer prompt" \
  "DTZ codes INCORRECTLY use docstring fixer prompt"

assert "t7d_generic_prompt" \
  "grep -q 'code quality fixer' '${t7d_dir}/prompt.txt' 2>/dev/null" \
  "DTZ codes use generic code quality fixer prompt" \
  "DTZ codes do NOT use generic prompt"

# ============================================================================
# Test 7f: Prompts do not contain Bash-dependent instructions
# ============================================================================
printf "\n--- test7f: prompts have no Bash-dependent instructions ---\n"

assert "t7f_no_ruff_format" \
  "! grep -q 'ruff format' '${t7a_dir}/prompt.txt' 2>/dev/null" \
  "docstring prompt has no 'ruff format' instruction" \
  "docstring prompt CONTAINS 'ruff format' (Bash not available)"

assert "t7f_no_ruff_check" \
  "! grep -q 'ruff check' '${t7a_dir}/prompt.txt' 2>/dev/null" \
  "docstring prompt has no 'ruff check' instruction" \
  "docstring prompt CONTAINS 'ruff check' (Bash not available)"

# ============================================================================
# Test 7g: Non-D-only violations use generic prompt
# ============================================================================
printf "\n--- test7g: non-D violations use generic prompt ---\n"

t7g_dir="${tmp_dir}/t7g"
setup_project_dir "${t7g_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t7g_dir}/bin" "${t7g_dir}/prompt.txt" "${t7g_dir}/args.txt"

printf 'import os\ndef hello():\n    """Say hello."""\n    pass\n' >"${t7g_dir}/test_file.py"

t7g_json='{"tool_input":{"file_path":"'"${t7g_dir}/test_file.py"'"}}'

export t7g_exit=0
echo "${t7g_json}" \
  | PATH="${t7g_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t7g_dir}/project" \
    HOOK_SESSION_PID="t7g_$$" \
    MOCK_RUFF_JSON="${F_ONLY_JSON}" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || t7g_exit=$?

assert "t7g_generic_prompt" \
  "grep -q 'code quality fixer' '${t7g_dir}/prompt.txt' 2>/dev/null" \
  "F-only violations use generic code quality fixer prompt" \
  "F-only violations did NOT use generic prompt"

assert "t7g_not_docstring" \
  "! grep -q 'docstring fixer' '${t7g_dir}/prompt.txt' 2>/dev/null" \
  "F-only violations do NOT use docstring fixer" \
  "F-only violations INCORRECTLY use docstring fixer"

# ============================================================================
# Test 7e: DL3000 (Dockerfile lint) does NOT trigger docstring branch
# ============================================================================
printf "\n--- test7e: DL3000 codes use generic prompt ---\n"

# DL3000 starts with "D" but is NOT a docstring code (Dockerfile lint rule)
DL_ONLY_JSON='[{"code":"DL3000","message":"Use absolute WORKDIR","location":{"row":2,"column":1},"end_location":{"row":2,"column":10},"fix":null,"filename":"Dockerfile","noqa_row":2,"url":"https://docs.astral.sh/ruff/rules/use-absolute-workdir"}]'

t7e_dir="${tmp_dir}/t7e"
setup_project_dir "${t7e_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t7e_dir}/bin" "${t7e_dir}/prompt.txt" "${t7e_dir}/args.txt"

printf 'FROM ubuntu\nWORKDIR relative/path\n' >"${t7e_dir}/test_file.py"

t7e_json='{"tool_input":{"file_path":"'"${t7e_dir}/test_file.py"'"}}'

export t7e_exit=0
echo "${t7e_json}" \
  | PATH="${t7e_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t7e_dir}/project" \
    HOOK_SESSION_PID="t7e_$$" \
    MOCK_RUFF_JSON="${DL_ONLY_JSON}" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || t7e_exit=$?

assert "t7e_not_docstring" \
  "! grep -q 'docstring fixer' '${t7e_dir}/prompt.txt' 2>/dev/null" \
  "DL3000 does NOT use docstring fixer prompt" \
  "DL3000 INCORRECTLY uses docstring fixer prompt"

assert "t7e_generic_prompt" \
  "grep -q 'code quality fixer' '${t7e_dir}/prompt.txt' 2>/dev/null" \
  "DL3000 uses generic code quality fixer prompt" \
  "DL3000 does NOT use generic prompt"

# ============================================================================
# Test 7h: HOOK_DEBUG_MODEL shows filtered D-only count
# ============================================================================
printf "\n--- test7h: HOOK_DEBUG_MODEL captures filtered subset ---\n"

t7h_dir="${tmp_dir}/t7h"
setup_project_dir "${t7h_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t7h_dir}/bin" "${t7h_dir}/prompt.txt" "${t7h_dir}/args.txt"

printf 'import os\ndef hello():\n    pass\n' >"${t7h_dir}/test_file.py"

t7h_json='{"tool_input":{"file_path":"'"${t7h_dir}/test_file.py"'"}}'

echo "${t7h_json}" \
  | PATH="${t7h_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t7h_dir}/project" \
    HOOK_SESSION_PID="t7h_$$" \
    MOCK_RUFF_JSON="${MIXED_D_F_JSON}" \
    HOOK_DEBUG_MODEL="1" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>"${t7h_dir}/stderr.txt" || true

assert "t7h_filtered_count" \
  "grep -q 'count=1' '${t7h_dir}/stderr.txt' 2>/dev/null" \
  "subprocess model uses filtered D-only count (1, not 2)" \
  "subprocess model does NOT show filtered count"

assert "t7h_model_sonnet" \
  "grep -q 'sonnet' '${t7h_dir}/stderr.txt' 2>/dev/null" \
  "mixed D+F violations select sonnet model" \
  "mixed D+F violations did NOT select sonnet"

# ============================================================================
# Test 7i: HOOK_DEBUG_MODEL uses D-only subset for Python docstring mix
# ============================================================================
printf "\n--- test7i: HOOK_DEBUG_MODEL uses D-filtered model for mixed D+opus ---\n"

# D103 + unresolved-attribute (opus-level code)
# Unfiltered: opus (unresolved-attribute in OPUS_PATTERN)
# D-only filtered: sonnet (D103 in SONNET_PATTERN)
MIXED_D_OPUS_JSON='[{"code":"D103","message":"Missing docstring","filename":"test.py","location":{"row":4,"column":1},"end_location":{"row":4,"column":10},"fix":null,"url":""},{"code":"unresolved-attribute","message":"Cannot access attribute","filename":"test.py","location":{"row":5,"column":1},"end_location":{"row":5,"column":10},"fix":null,"url":""}]'

t7i_dir="${tmp_dir}/t7i"
setup_project_dir "${t7i_dir}/project" "${TIER_CONFIG}"
create_mock_claude "${t7i_dir}/bin" "${t7i_dir}/prompt.txt" "${t7i_dir}/args.txt"

printf 'import os\ndef hello():\n    pass\n' >"${t7i_dir}/test_file.py"

t7i_json='{"tool_input":{"file_path":"'"${t7i_dir}/test_file.py"'"}}'

echo "${t7i_json}" \
  | PATH="${t7i_dir}/bin:${mock_bin}:${PATH}" \
    CLAUDE_PROJECT_DIR="${t7i_dir}/project" \
    HOOK_SESSION_PID="t7i_$$" \
    MOCK_RUFF_JSON="${MIXED_D_OPUS_JSON}" \
    HOOK_DEBUG_MODEL="1" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>"${t7i_dir}/stderr.txt" || true

assert "t7i_model_sonnet" \
  "grep -q '\[hook:model\] sonnet' '${t7i_dir}/stderr.txt' 2>/dev/null" \
  "[hook:model] says sonnet for D103+opus-code (filtered to D-only)" \
  "[hook:model] does NOT say sonnet after D-filtering"

assert "t7i_not_opus" \
  "! grep -q '\[hook:model\] opus' '${t7i_dir}/stderr.txt' 2>/dev/null" \
  "[hook:model] does NOT say opus (unresolved-attribute filtered out)" \
  "[hook:model] incorrectly says opus (unfiltered set used)"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
