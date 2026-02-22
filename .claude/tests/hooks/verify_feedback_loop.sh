#!/bin/bash
# verify_feedback_loop.sh - Standalone verification harness for multi-linter hook feedback loop
#
# Automates Step 2 of docs/specs/posttooluse-issue/make-plankton-work.md.
# Verifies that multi_linter.sh produces correct output (stderr JSON with [hook] prefix,
# exit code 2) when violations exist, using HOOK_SKIP_SUBPROCESS=1 test mode.
#
# Usage:
#   bash .claude/tests/hooks/verify_feedback_loop.sh
#   # or from project root:
#   .claude/tests/hooks/verify_feedback_loop.sh

set -euo pipefail

# --- Path resolution ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_dir="$(cd "${script_dir}/../../hooks" && pwd)"
project_dir="$(cd "${script_dir}/../../.." && pwd)"

# --- Temp directory with cleanup trap ---
tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}" "${project_dir}/test_fixture_broken.toml"' EXIT

# --- Shared test fixture (decouples tests from production config) ---
fixture_project_dir="${tmp_dir}/fixture_project"
mkdir -p "${fixture_project_dir}/.claude/hooks"
fixtures_dir="$(dirname "${BASH_SOURCE[0]}")/fixtures"
cp "${fixtures_dir}/config.json" "${fixture_project_dir}/.claude/hooks/config.json"
cp "${fixtures_dir}/.markdownlint-cli2.jsonc" "${fixture_project_dir}/.markdownlint-cli2.jsonc"
# Copy .markdownlint.jsonc rules file from fixtures
cp "${fixtures_dir}/.markdownlint.jsonc" "${fixture_project_dir}/.markdownlint.jsonc"

# --- Counters ---
passed=0
failed=0
skipped=0
skip_reasons=()

# --- Check function ---
run_check() {
  local name="$1"
  local file="$2"
  local expected_min="$3"
  local json_input
  json_input='{"tool_input":{"file_path":"'"${file}"'"}}'

  printf "\n--- %s ---\n" "${name}"

  # Capture stderr only; discard stdout
  local stderr_output=""
  local actual_exit=0
  stderr_output=$(echo "${json_input}" \
    | HOOK_SKIP_SUBPROCESS=1 CLAUDE_PROJECT_DIR="${fixture_project_dir}" \
      bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || actual_exit=$?

  # Helper: record pass or fail
  _assert() {
    local tag="$1" cond="$2" pass_msg="$3" fail_msg="$4"
    if eval "${cond}"; then
      printf "  PASS %s: %s\n" "${tag}" "${pass_msg}"
      passed=$((passed + 1))
    else
      printf "  FAIL %s: %s\n" "${tag}" "${fail_msg}"
      failed=$((failed + 1))
    fi
  }

  # Check 1: exit code must be 2
  _assert "${name}_exit" "[[ ${actual_exit} -eq 2 ]]" \
    "exit code 2" "exit code ${actual_exit} (expected 2)"

  # The hook may emit multiple "[hook] " lines (e.g., markdown debug summary).
  # The JSON payload is on the LAST "[hook] " prefixed line/block.
  local last_hook_output=""
  last_hook_output=$(echo "${stderr_output}" | grep -n '^\[hook\] ' | tail -1 || true)
  local hook_line_num="${last_hook_output%%:*}"

  # Check 2: stderr must contain at least one "[hook] " prefix
  _assert "${name}_prefix" "[[ -n '${hook_line_num}' ]]" \
    "[hook] prefix present" "missing [hook] prefix"

  # Extract JSON payload from the last [hook] line onward, minus the prefix
  local json_payload=""
  if [[ -n "${hook_line_num}" ]]; then
    json_payload=$(echo "${stderr_output}" | tail -n +"${hook_line_num}")
    json_payload="${json_payload#\[hook\] }"
  fi

  # Check 3: JSON must be valid array
  local json_type=""
  json_type=$(echo "${json_payload}" | jaq type 2>/dev/null) || json_type=""
  _assert "${name}_json" "[[ '${json_type}' == '\"array\"' ]]" \
    "valid JSON array" "not a valid JSON array (type: ${json_type:-null})"

  # Check 4: array length >= expected_min
  local count=0
  count=$(echo "${json_payload}" | jaq 'length' 2>/dev/null) || count=0
  _assert "${name}_count" "[[ ${count} -ge ${expected_min} ]]" \
    "${count} violations (>= ${expected_min})" "${count} violations (expected >= ${expected_min})"
}

# --- Gate helper: skip if linter not available ---
# Sets _gl_available=1 (available) or _gl_available=0 (skipped)
gate_linter() {
  local linter="$1"
  local label="$2"
  if command -v "${linter}" >/dev/null 2>&1; then
    _gl_available=1
  else
    _gl_available=0
    skip_reasons+=("${label}: ${linter} not installed")
    skipped=$((skipped + 4))
    printf "\n--- %s ---\n" "${label}"
    printf "  SKIP (4 checks): %s not installed\n" "${linter}"
  fi
}

# === Begin tests ===
printf "=== Feedback Loop Verification ===\n"

# --- Python (ruff) ---
# ruff is required by the project, always available
py_file="${tmp_dir}/test.py"
printf '"""Module."""\n\n\ndef foo():\n    """Do nothing."""\n    x = 1\n    return 42\n' >"${py_file}"
run_check "python" "${py_file}" 1

# --- Shell (shellcheck) ---
gate_linter "shellcheck" "shell"
if [[ "${_gl_available}" -eq 1 ]]; then
  sh_file="${tmp_dir}/test.sh"
  printf "#!/bin/bash\nunused=\"x\"\necho \$y\n" >"${sh_file}"
  run_check "shell" "${sh_file}" 2
fi

# --- JSON (built-in jaq syntax check) ---
json_file="${tmp_dir}/test.json"
printf '{invalid}\n' >"${json_file}"
run_check "json" "${json_file}" 1

# --- YAML (yamllint) ---
gate_linter "yamllint" "yaml"
if [[ "${_gl_available}" -eq 1 ]]; then
  yaml_file="${tmp_dir}/test.yaml"
  printf 'key: value\n bad_indent: true\n' >"${yaml_file}"
  run_check "yaml" "${yaml_file}" 1
fi

# --- Dockerfile (hadolint) ---
gate_linter "hadolint" "dockerfile"
if [[ "${_gl_available}" -eq 1 ]]; then
  dockerfile="${tmp_dir}/Dockerfile"
  printf 'FROM ubuntu\nRUN apt-get update\n' >"${dockerfile}"
  run_check "dockerfile" "${dockerfile}" 1
fi

# --- TOML (taplo) ---
# taplo respects taplo.toml include patterns, so the fixture must be inside the
# project tree (files in /tmp are outside the include glob and get excluded).
gate_linter "taplo" "toml"
if [[ "${_gl_available}" -eq 1 ]]; then
  # taplo resolves include globs relative to CWD (project root), so the
  # fixture must be inside the project tree. Cleanup is EXIT-trapped.
  toml_file="${project_dir}/test_fixture_broken.toml"
  printf '[broken\nkey = "value"\n' >"${toml_file}"
  run_check "toml" "${toml_file}" 1
fi

# --- Markdown (markdownlint-cli2) ---
gate_linter "markdownlint-cli2" "markdown"
if [[ "${_gl_available}" -eq 1 ]]; then
  md_file="${tmp_dir}/test.md"
  # Generate a line with 201 characters to trigger MD013
  printf 'x%.0s' {1..201} >"${md_file}"
  printf '\n' >>"${md_file}"
  run_check "markdown" "${md_file}" 1
fi

# --- TypeScript (biome + config check) ---
_ts_reason=""
if ! command -v biome >/dev/null 2>&1; then
  _ts_reason="biome not installed"
else
  ts_enabled=$(jaq -r '.languages.typescript.enabled // true' \
    "${fixture_project_dir}/.claude/hooks/config.json" 2>/dev/null) || ts_enabled="false"
  [[ "${ts_enabled}" != "true" ]] && _ts_reason="not enabled in config"
fi
if [[ -n "${_ts_reason}" ]]; then
  skip_reasons+=("typescript: ${_ts_reason}")
  skipped=$((skipped + 4))
  printf "\n--- typescript ---\n  SKIP (4 checks): %s\n" "${_ts_reason}"
else
  ts_file="${tmp_dir}/test.ts"
  printf 'const unused = "x";\nconsole.log("test");\n' >"${ts_file}"
  run_check "typescript" "${ts_file}" 1
fi

# === Summary ===
_skip_detail=""
for r in "${skip_reasons[@]+"${skip_reasons[@]}"}"; do
  [[ -n "${_skip_detail}" ]] && _skip_detail+=", "
  _skip_detail+="${r}"
done
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\nSkipped: %d" "${passed}" "${failed}" "${skipped}"
[[ -n "${_skip_detail}" ]] && printf " (%s)" "${_skip_detail}"
printf "\n"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
