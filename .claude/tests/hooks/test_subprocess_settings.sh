#!/bin/bash
# test_subprocess_settings.sh - Tests subprocess settings file configuration
#
# Verifies that:
# - Default settings path is project-local .claude/subprocess-settings.json
# - config.json settings_file override is respected
# - Settings file has correct keys
# - No remaining references to no-hooks-settings.json
#
# Usage: bash .claude/tests/hooks/test_subprocess_settings.sh

set -euo pipefail

# --- Path resolution ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_dir="$(cd "${script_dir}/../../hooks" && pwd)"
project_dir="$(cd "${script_dir}/../../.." && pwd)"

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
}

# --- Helper: create shell file with ShellCheck violations ---
create_bad_shell_file() {
  local fp="$1"
  printf "#!/bin/bash\nunused=\"x\"\necho \$y\n" >"${fp}"
}

# Tier config with no settings_file override
TIER_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "SC[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120}
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}'

# === Begin tests ===
printf "=== Subprocess Settings Tests ===\n"

# ============================================================================
# Test 2a: default settings path is project-local
# ============================================================================
printf "\n--- test2a: default project-local settings ---\n"

t2a_dir="${tmp_dir}/t2a"
mkdir -p "${t2a_dir}/bin"

t2a_args="${t2a_dir}/claude_args.txt"
cat >"${t2a_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t2a_args}"
exit 0
MOCK_EOF
chmod +x "${t2a_dir}/bin/claude"

setup_project_dir "${t2a_dir}/project" "${TIER_CONFIG}"

# Create the project-local settings file (as the hook would expect)
mkdir -p "${t2a_dir}/project/.claude"
cat >"${t2a_dir}/project/.claude/subprocess-settings.json" <<'SETTINGS_EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
SETTINGS_EOF

t2a_file="${t2a_dir}/test.sh"
create_bad_shell_file "${t2a_file}"

t2a_json='{"tool_input":{"file_path":"'"${t2a_file}"'"}}'

export t2a_exit=0
echo "${t2a_json}" \
  | PATH="${t2a_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t2a_dir}/project" \
    HOOK_SESSION_PID="t2a_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || t2a_exit=$?

assert "t2a_project_local" \
  "grep -q 'subprocess-settings.json' '${t2a_args}'" \
  "--settings points to subprocess-settings.json" \
  "--settings does NOT point to subprocess-settings.json"

assert "t2a_no_hooks_settings" \
  "! grep -q 'no-hooks-settings' '${t2a_args}'" \
  "no reference to no-hooks-settings.json" \
  "still references no-hooks-settings.json"

# ============================================================================
# Test 2b: config.json settings_file override
# ============================================================================
printf "\n--- test2b: config.json settings_file override ---\n"

OVERRIDE_SETTINGS_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "SC[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120}
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": "/tmp/custom-settings.json"
  }
}'

t2b_dir="${tmp_dir}/t2b"
mkdir -p "${t2b_dir}/bin"

t2b_args="${t2b_dir}/claude_args.txt"
cat >"${t2b_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t2b_args}"
exit 0
MOCK_EOF
chmod +x "${t2b_dir}/bin/claude"

setup_project_dir "${t2b_dir}/project" "${OVERRIDE_SETTINGS_CONFIG}"

# Create the custom settings file
cat >"/tmp/custom-settings.json" <<'SETTINGS_EOF'
{
  "disableAllHooks": true
}
SETTINGS_EOF

t2b_file="${t2b_dir}/test.sh"
create_bad_shell_file "${t2b_file}"

t2b_json='{"tool_input":{"file_path":"'"${t2b_file}"'"}}'

export t2b_exit=0
echo "${t2b_json}" \
  | PATH="${t2b_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t2b_dir}/project" \
    HOOK_SESSION_PID="t2b_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || t2b_exit=$?

assert "t2b_custom_path" \
  "grep -q 'custom-settings.json' '${t2b_args}'" \
  "custom settings_file path used" \
  "custom settings_file path NOT used"

# Clean up
rm -f /tmp/custom-settings.json

# ============================================================================
# Test 2c: subprocess-settings.json has correct keys
# ============================================================================
printf "\n--- test2c: subprocess-settings.json content ---\n"

settings_file="${project_dir}/.claude/subprocess-settings.json"

assert "t2c_exists" \
  "[[ -f '${settings_file}' ]]" \
  "subprocess-settings.json exists" \
  "subprocess-settings.json MISSING"

if [[ -f "${settings_file}" ]]; then
  assert "t2c_disable_hooks" \
    "jaq -r '.disableAllHooks' '${settings_file}' 2>/dev/null | grep -q 'true'" \
    "disableAllHooks=true" \
    "disableAllHooks not true"

  assert "t2c_skip_prompt" \
    "jaq -r '.skipDangerousModePermissionPrompt' '${settings_file}' 2>/dev/null | grep -q 'true'" \
    "skipDangerousModePermissionPrompt=true" \
    "skipDangerousModePermissionPrompt not true"
else
  # File missing — fail the content checks
  assert "t2c_disable_hooks" "false" "n/a" "file missing"
  assert "t2c_skip_prompt" "false" "n/a" "file missing"
fi

# ============================================================================
# Test 2d: no remaining references to no-hooks-settings.json
# ============================================================================
printf "\n--- test2d: no remaining no-hooks-settings references ---\n"

# Search code files (exclude .git, node_modules, this test file, and the spec file
# which intentionally documents the old state)
nohooks_files=$(grep -r --include='*.sh' --include='*.json' --include='*.md' \
  'no-hooks-settings' "${project_dir}" \
  --exclude-dir=.git --exclude-dir=node_modules \
  --exclude-dir=__pycache__ --exclude-dir=.venv \
  -l 2>/dev/null \
  | grep -v 'test_subprocess_settings\.sh' \
  | grep -v 'subprocess-permission-gap\.md' || true)
nohooks_count=0
if [[ -n "${nohooks_files}" ]]; then
  nohooks_count=$(echo "${nohooks_files}" | wc -l | tr -d ' ')
fi

assert "t2d_no_references" \
  "[[ '${nohooks_count}' -eq 0 ]]" \
  "zero references to no-hooks-settings.json" \
  "${nohooks_count} files still reference no-hooks-settings.json"

# ============================================================================
# Test 2e: tilde expansion in settings_file
# ============================================================================
printf "\n--- test2e: tilde expansion in settings_file ---\n"

TILDE_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "SC[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120}
    },
    "global_model_override": null, "max_turns_override": null, "timeout_override": null, "volume_threshold": 5,
    "settings_file": "~/custom-settings.json"
  }
}'

t2e_dir="${tmp_dir}/t2e"
mkdir -p "${t2e_dir}/bin"
t2e_args="${t2e_dir}/claude_args.txt"
cat >"${t2e_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t2e_args}"
exit 0
MOCK_EOF
chmod +x "${t2e_dir}/bin/claude"
setup_project_dir "${t2e_dir}/project" "${TILDE_CONFIG}"

# Create the settings file at the expanded path
cat >"${isolated_home}/custom-settings.json" <<'SETTINGS_EOF'
{"disableAllHooks": true}
SETTINGS_EOF

t2e_file="${t2e_dir}/test.sh"
create_bad_shell_file "${t2e_file}"
t2e_json='{"tool_input":{"file_path":"'"${t2e_file}"'"}}'

export t2e_exit=0
echo "${t2e_json}" \
  | PATH="${t2e_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t2e_dir}/project" \
    HOOK_SESSION_PID="t2e_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || t2e_exit=$?

assert "t2e_tilde_expanded" \
  "grep -q '${isolated_home}/custom-settings.json' '${t2e_args}'" \
  "tilde expanded to HOME in settings path" \
  "tilde NOT expanded (literal ~ in path)"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
