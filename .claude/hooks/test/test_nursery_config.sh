#!/usr/bin/env bash
# test_nursery_config.sh — Tests _validate_nursery_config() behavior
#
# Verifies:
# - N1: object-valued nursery in biome.json (e.g., {"recommended": true})
#       does NOT emit a biome_nursery mismatch warning
# - N2: string-valued nursery mismatch DOES emit warning (regression guard)
#
# Usage: bash .claude/tests/hooks/test_nursery_config.sh

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

# --- Gate: jaq required ---
if ! command -v jaq >/dev/null 2>&1; then
  printf "SKIP: jaq not installed\n"
  exit 0
fi

# --- Isolate HOME ---
isolated_home="${tmp_dir}/home"
mkdir -p "${isolated_home}/.claude"
export HOME="${isolated_home}"

# --- Helper: create minimal project dir ---
setup_ts_project() {
  local pd="$1"
  local biome_nursery_val="$2"  # biome.json nursery value (raw JSON fragment)
  local config_nursery_val="$3" # config.json biome_nursery string value

  mkdir -p "${pd}/.claude/hooks"
  mkdir -p "${pd}/node_modules/.bin"

  # biome.json
  cat >"${pd}/biome.json" <<BIOME_EOF
{
  "\$schema": "https://biomejs.dev/schemas/2.3.15/schema.json",
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "nursery": ${biome_nursery_val}
    }
  }
}
BIOME_EOF

  # config.json — typescript enabled, subprocess disabled
  cat >"${pd}/.claude/hooks/config.json" <<CONFIG_EOF
{
  "languages": {
    "typescript": {
      "enabled": true,
      "biome_nursery": "${config_nursery_val}"
    }
  },
  "phases": { "subprocess_delegation": false },
  "security_linter_exclusions": []
}
CONFIG_EOF

  # subprocess-settings (required by hook even when delegation is off)
  cat >"${pd}/.claude/subprocess-settings.json" <<'SETTINGS_EOF'
{
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
SETTINGS_EOF

  # Mock biome: returns empty violations so the test is fast
  cat >"${pd}/node_modules/.bin/biome" <<'MOCK_EOF'
#!/usr/bin/env bash
# Return empty JSON diagnostics for any invocation
echo '{"summary":{"changed":0,"unchanged":1,"errors":0,"warnings":0},"diagnostics":[]}'
exit 0
MOCK_EOF
  chmod +x "${pd}/node_modules/.bin/biome"
}

printf "=== Nursery Config Validation Tests ===\n"

# ============================================================================
# Test N1: object-valued nursery in biome.json does NOT emit mismatch warning
# ============================================================================
printf "\n--- test_n1: object nursery suppresses mismatch warning ---\n"

test_n1_dir="${tmp_dir}/test_n1"
# biome.json has nursery as object; config.json says "warn" (string)
setup_ts_project "${test_n1_dir}" '{ "recommended": true }' "warn"

test_n1_ts="${test_n1_dir}/test.ts"
echo 'const x = 1;' >"${test_n1_ts}"

test_n1_stderr="${tmp_dir}/test_n1_stderr.txt"
echo '{"tool_input":{"file_path":"'"${test_n1_ts}"'"}}' \
  | CLAUDE_PROJECT_DIR="${test_n1_dir}" \
    HOOK_SESSION_PID="test_n1_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>"${test_n1_stderr}" || true

assert "test_n1_no_nursery_warning" \
  "! grep -q 'biome_nursery' '${test_n1_stderr}'" \
  "No biome_nursery mismatch warning for object nursery (correct)" \
  "biome_nursery mismatch warning still emitted for object nursery (bug: [[ \"\${biome_nursery}\" == \"{\"* ]] guard missing)"

# ============================================================================
# Test N2: string nursery mismatch STILL emits warning (regression guard)
# ============================================================================
printf "\n--- test_n2: string nursery mismatch still warns ---\n"

test_n2_dir="${tmp_dir}/test_n2"
# biome.json has nursery: "warn" (string); config.json says "error" (mismatch)
setup_ts_project "${test_n2_dir}" '"warn"' "error"

test_n2_ts="${test_n2_dir}/test.ts"
echo 'const x = 1;' >"${test_n2_ts}"

test_n2_stderr="${tmp_dir}/test_n2_stderr.txt"
echo '{"tool_input":{"file_path":"'"${test_n2_ts}"'"}}' \
  | CLAUDE_PROJECT_DIR="${test_n2_dir}" \
    HOOK_SESSION_PID="test_n2_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>"${test_n2_stderr}" || true

assert "test_n2_string_mismatch_warns" \
  "grep -q 'biome_nursery' '${test_n2_stderr}'" \
  "biome_nursery mismatch warning emitted for string mismatch (correct)" \
  "biome_nursery mismatch warning NOT emitted for string mismatch (regression)"

# ============================================================================
# Test N3: array-valued nursery in biome.json does NOT emit mismatch warning
# ============================================================================
printf "\n--- test_n3: array nursery suppresses mismatch warning ---\n"

test_n3_dir="${tmp_dir}/test_n3"
# biome.json has nursery as array (hypothetical but guard must handle it)
setup_ts_project "${test_n3_dir}" '["rule1", "rule2"]' "warn"

test_n3_ts="${test_n3_dir}/test.ts"
echo 'const x = 1;' >"${test_n3_ts}"

test_n3_stderr="${tmp_dir}/test_n3_stderr.txt"
echo '{"tool_input":{"file_path":"'"${test_n3_ts}"'"}}' \
  | CLAUDE_PROJECT_DIR="${test_n3_dir}" \
    HOOK_SESSION_PID="test_n3_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>"${test_n3_stderr}" || true

assert "test_n3_no_nursery_warning" \
  "! grep -q 'biome_nursery' '${test_n3_stderr}'" \
  "No biome_nursery mismatch warning for array nursery (correct)" \
  "biome_nursery mismatch warning emitted for array nursery (bug: [\"* guard missing)"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
