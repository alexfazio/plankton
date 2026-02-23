#!/bin/bash
# test_tier_config.sh - Tests per-tier subprocess configuration
#
# Verifies tier selection, overrides, backwards compatibility errors,
# and disallowedTools derivation from per-tier tool lists.
#
# Usage: bash .claude/tests/hooks/test_tier_config.sh

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

# --- Helper: create shell file with specific violation code ---
create_shell_file_with_violation() {
  local fp="$1"
  # Simple shell file that triggers shellcheck violations
  printf "#!/bin/bash\nunused=\"x\"\necho \$y\n" >"${fp}"
}

# --- Tier config template ---
# Uses the new subprocess.tiers structure
TIER_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "E[0-9]+|W[0-9]+|F[0-9]+|SC[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "C901|PLR[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "unresolved-attribute|type-assertion", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}'

# === Begin tests ===
printf "=== Tier Config Tests ===\n"

# ============================================================================
# Test 1.5a: haiku tier selected for simple codes (SC2034, SC2086)
# ============================================================================
printf "\n--- test1.5a: haiku for simple codes ---\n"

t15a_dir="${tmp_dir}/t15a"
mkdir -p "${t15a_dir}/bin"

# Mock claude that logs args
t15a_args="${t15a_dir}/claude_args.txt"
cat >"${t15a_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t15a_args}"
exit 0
MOCK_EOF
chmod +x "${t15a_dir}/bin/claude"

setup_project_dir "${t15a_dir}/project" "${TIER_CONFIG}"

t15a_file="${t15a_dir}/test.sh"
create_shell_file_with_violation "${t15a_file}"

t15a_json='{"tool_input":{"file_path":"'"${t15a_file}"'"}}'

export t15a_exit=0
t15a_stderr=$(echo "${t15a_json}" \
  | PATH="${t15a_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t15a_dir}/project" \
    HOOK_SESSION_PID="t15a_$$" \
    HOOK_DEBUG_MODEL=1 \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || t15a_exit=$?

assert "t15a_haiku" \
  "echo '${t15a_stderr}' | grep -q '\\[hook:model\\] haiku'" \
  "haiku selected for SC codes" \
  "haiku NOT selected for simple SC codes"

# ============================================================================
# Test 1.5b: sonnet tier selected for C901/PLR codes
# ============================================================================
printf "\n--- test1.5b: sonnet for complex codes ---\n"

# This test requires a Python file with C901 violation
# We'll use HOOK_DEBUG_MODEL to check model selection
# For now, verify the model selection log for a config that forces sonnet patterns
t15b_dir="${tmp_dir}/t15b"
mkdir -p "${t15b_dir}/bin"

t15b_args="${t15b_dir}/claude_args.txt"
cat >"${t15b_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t15b_args}"
exit 0
MOCK_EOF
chmod +x "${t15b_dir}/bin/claude"

setup_project_dir "${t15b_dir}/project" "${TIER_CONFIG}"

# Create a Python file — we need ruff to produce C901 or PLR codes
# Since we can't guarantee ruff produces C901, we test via model debug output
# The key assertion: if the config has tiers, the load_model_patterns function
# reads from tiers.sonnet.patterns instead of model_selection.sonnet_patterns
# We can verify by checking the stderr for the tier-based log format
t15b_file="${t15b_dir}/test.sh"
create_shell_file_with_violation "${t15b_file}"

t15b_json='{"tool_input":{"file_path":"'"${t15b_file}"'"}}'

export t15b_exit=0
t15b_stderr=$(echo "${t15b_json}" \
  | PATH="${t15b_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t15b_dir}/project" \
    HOOK_SESSION_PID="t15b_$$" \
    HOOK_DEBUG_MODEL=1 \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || t15b_exit=$?

# With SC codes and tier config, haiku patterns should match (SC[0-9]+)
# Sonnet test: verify the config is read from tiers structure
# (The actual sonnet selection would need a C901 violation — covered by stress tests)
assert "t15b_haiku_for_sc" \
  "echo '${t15b_stderr}' | grep -q '\\[hook:model\\] haiku'" \
  "haiku selected for SC codes with default tier config" \
  "haiku NOT selected (expected haiku for SC codes)"

# ============================================================================
# Test 1.5b2: sonnet tier selected when SC codes match sonnet patterns
# ============================================================================
printf "\n--- test1.5b2: sonnet for SC codes (sonnet-matched config) ---\n"

SONNET_SC_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "XYZZY[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "SC[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "FROTZ[0-9]+", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": null, "max_turns_override": null, "timeout_override": null, "volume_threshold": 5, "settings_file": null
  }
}'

t15b2_dir="${tmp_dir}/t15b2"
mkdir -p "${t15b2_dir}/bin"
t15b2_args="${t15b2_dir}/claude_args.txt"
cat >"${t15b2_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t15b2_args}"
exit 0
MOCK_EOF
chmod +x "${t15b2_dir}/bin/claude"
setup_project_dir "${t15b2_dir}/project" "${SONNET_SC_CONFIG}"
t15b2_file="${t15b2_dir}/test.sh"
create_shell_file_with_violation "${t15b2_file}"
t15b2_json='{"tool_input":{"file_path":"'"${t15b2_file}"'"}}'
export t15b2_exit=0
t15b2_stderr=$(echo "${t15b2_json}" \
  | PATH="${t15b2_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t15b2_dir}/project" \
    HOOK_SESSION_PID="t15b2_$$" \
    HOOK_DEBUG_MODEL=1 \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || t15b2_exit=$?

assert "t15b2_sonnet" \
  "echo '${t15b2_stderr}' | grep -q '\\[hook:model\\] sonnet'" \
  "sonnet selected when SC codes match sonnet patterns" \
  "sonnet NOT selected (expected sonnet)"

# ============================================================================
# Test 1.5c: opus tier selected when SC codes match opus patterns
# ============================================================================
printf "\n--- test1.5c: opus for SC codes (opus-matched config) ---\n"

OPUS_SC_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "XYZZY[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "PLUGH[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "SC[0-9]+", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": null, "max_turns_override": null, "timeout_override": null, "volume_threshold": 5, "settings_file": null
  }
}'

t15c_dir="${tmp_dir}/t15c"
mkdir -p "${t15c_dir}/bin"
t15c_args="${t15c_dir}/claude_args.txt"
cat >"${t15c_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t15c_args}"
exit 0
MOCK_EOF
chmod +x "${t15c_dir}/bin/claude"
setup_project_dir "${t15c_dir}/project" "${OPUS_SC_CONFIG}"
t15c_file="${t15c_dir}/test.sh"
create_shell_file_with_violation "${t15c_file}"
t15c_json='{"tool_input":{"file_path":"'"${t15c_file}"'"}}'
export t15c_exit=0
t15c_stderr=$(echo "${t15c_json}" \
  | PATH="${t15c_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t15c_dir}/project" \
    HOOK_SESSION_PID="t15c_$$" \
    HOOK_DEBUG_MODEL=1 \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || t15c_exit=$?

assert "t15c_opus" \
  "echo '${t15c_stderr}' | grep -q '\\[hook:model\\] opus'" \
  "opus selected when SC codes match opus patterns" \
  "opus NOT selected (expected opus)"

# ============================================================================
# Test 1.5d: unmatched pattern falls back to haiku with warning
# ============================================================================
printf "\n--- test1.5d: unmatched pattern warning ---\n"

# Config where patterns are very narrow — SC codes won't match any tier
NARROW_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "XYZZY[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "PLUGH[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "FROTZ[0-9]+", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}'

t15d_dir="${tmp_dir}/t15d"
mkdir -p "${t15d_dir}/bin"

t15d_args="${t15d_dir}/claude_args.txt"
cat >"${t15d_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t15d_args}"
exit 0
MOCK_EOF
chmod +x "${t15d_dir}/bin/claude"

setup_project_dir "${t15d_dir}/project" "${NARROW_CONFIG}"

t15d_file="${t15d_dir}/test.sh"
create_shell_file_with_violation "${t15d_file}"

t15d_json='{"tool_input":{"file_path":"'"${t15d_file}"'"}}'

export t15d_exit=0
t15d_stderr=$(echo "${t15d_json}" \
  | PATH="${t15d_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t15d_dir}/project" \
    HOOK_SESSION_PID="t15d_$$" \
    HOOK_DEBUG_MODEL=1 \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || t15d_exit=$?

assert "t15d_warning" \
  "echo '${t15d_stderr}' | grep -q '\\[hook:warning\\] unmatched pattern'" \
  "unmatched pattern warning emitted" \
  "unmatched pattern warning NOT emitted"

assert "t15d_haiku_default" \
  "echo '${t15d_stderr}' | grep -q '\\[hook:model\\] haiku'" \
  "defaults to haiku for unmatched codes" \
  "did NOT default to haiku"

# ============================================================================
# Test 1.5e: global_model_override skips tier selection
# ============================================================================
printf "\n--- test1.5e: global_model_override ---\n"

OVERRIDE_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "E[0-9]+|W[0-9]+|F[0-9]+|SC[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "C901|PLR[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "unresolved-attribute|type-assertion", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": "sonnet",
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}'

t15e_dir="${tmp_dir}/t15e"
mkdir -p "${t15e_dir}/bin"

t15e_args="${t15e_dir}/claude_args.txt"
cat >"${t15e_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t15e_args}"
exit 0
MOCK_EOF
chmod +x "${t15e_dir}/bin/claude"

setup_project_dir "${t15e_dir}/project" "${OVERRIDE_CONFIG}"

t15e_file="${t15e_dir}/test.sh"
create_shell_file_with_violation "${t15e_file}"

t15e_json='{"tool_input":{"file_path":"'"${t15e_file}"'"}}'

export t15e_exit=0
t15e_stderr=$(echo "${t15e_json}" \
  | PATH="${t15e_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t15e_dir}/project" \
    HOOK_SESSION_PID="t15e_$$" \
    HOOK_DEBUG_MODEL=1 \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || t15e_exit=$?

assert "t15e_override" \
  "echo '${t15e_stderr}' | grep -q '\\[hook:model\\] sonnet'" \
  "global_model_override forces sonnet" \
  "global_model_override did NOT force sonnet (expected sonnet for SC codes with override)"

# ============================================================================
# Test 1.5g: per-tier max_turns (haiku=10, opus=15)
# ============================================================================
printf "\n--- test1.5g: per-tier max_turns ---\n"

# Haiku case: SC codes should use max_turns=10
assert "t15g_haiku_turns" \
  "grep -q -- '--max-turns' '${t15a_args}' && grep -A1 -- '--max-turns' '${t15a_args}' | grep -q '10'" \
  "haiku max_turns=10" \
  "haiku max_turns not 10"

# ============================================================================
# Test 1.5h: max_turns_override
# ============================================================================
printf "\n--- test1.5h: max_turns_override ---\n"

TURNS_OVERRIDE_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "SC[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "C901", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "unresolved-attribute", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": null,
    "max_turns_override": 25,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}'

t15h_dir="${tmp_dir}/t15h"
mkdir -p "${t15h_dir}/bin"

t15h_args="${t15h_dir}/claude_args.txt"
cat >"${t15h_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t15h_args}"
exit 0
MOCK_EOF
chmod +x "${t15h_dir}/bin/claude"

setup_project_dir "${t15h_dir}/project" "${TURNS_OVERRIDE_CONFIG}"

t15h_file="${t15h_dir}/test.sh"
create_shell_file_with_violation "${t15h_file}"

t15h_json='{"tool_input":{"file_path":"'"${t15h_file}"'"}}'

export t15h_exit=0
echo "${t15h_json}" \
  | PATH="${t15h_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t15h_dir}/project" \
    HOOK_SESSION_PID="t15h_$$" \
    bash "${hook_dir}/multi_linter.sh" >/dev/null 2>&1 || t15h_exit=$?

assert "t15h_turns_override" \
  "grep -q '25' '${t15h_args}'" \
  "max_turns_override=25 applied" \
  "max_turns_override=25 NOT found in args"

# ============================================================================
# Test 1.5i: per-tier timeout (haiku=120)
# ============================================================================
printf "\n--- test1.5i: per-tier timeout ---\n"

# Verify the subprocess log shows timeout=120 for haiku tier
assert "t15i_haiku_timeout" \
  "echo '${t15a_stderr}' | grep -q 'timeout=120'" \
  "haiku timeout=120" \
  "haiku timeout not 120"

# ============================================================================
# Test 1.5j: timeout_override
# ============================================================================
printf "\n--- test1.5j: timeout_override ---\n"

TIMEOUT_OVERRIDE_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "SC[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "C901", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "unresolved-attribute", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": null, "max_turns_override": null, "timeout_override": 999, "volume_threshold": 5, "settings_file": null
  }
}'

t15j_dir="${tmp_dir}/t15j"
mkdir -p "${t15j_dir}/bin"
t15j_args="${t15j_dir}/claude_args.txt"
cat >"${t15j_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t15j_args}"
exit 0
MOCK_EOF
chmod +x "${t15j_dir}/bin/claude"
setup_project_dir "${t15j_dir}/project" "${TIMEOUT_OVERRIDE_CONFIG}"
t15j_file="${t15j_dir}/test.sh"
create_shell_file_with_violation "${t15j_file}"
t15j_json='{"tool_input":{"file_path":"'"${t15j_file}"'"}}'
export t15j_exit=0
t15j_stderr=$(echo "${t15j_json}" \
  | PATH="${t15j_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t15j_dir}/project" \
    HOOK_SESSION_PID="t15j_$$" \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || t15j_exit=$?

assert "t15j_timeout_override" \
  "echo '${t15j_stderr}' | grep -q 'timeout=999'" \
  "timeout_override=999 applied" \
  "timeout_override=999 NOT found in stderr"

# ============================================================================
# Test 1.5k: old flat config keys produce error
# ============================================================================
printf "\n--- test1.5k: old flat config error ---\n"

OLD_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "timeout": 300,
    "model_selection": {
      "sonnet_patterns": "C901",
      "opus_patterns": "unresolved-attribute",
      "volume_threshold": 5
    }
  }
}'

t15k_dir="${tmp_dir}/t15k"
mkdir -p "${t15k_dir}/bin"

cat >"${t15k_dir}/bin/claude" <<'MOCK_EOF'
#!/bin/bash
exit 0
MOCK_EOF
chmod +x "${t15k_dir}/bin/claude"

setup_project_dir "${t15k_dir}/project" "${OLD_CONFIG}"

t15k_file="${t15k_dir}/test.sh"
create_shell_file_with_violation "${t15k_file}"

t15k_json='{"tool_input":{"file_path":"'"${t15k_file}"'"}}'

export t15k_exit=0
t15k_stderr=$(echo "${t15k_json}" \
  | PATH="${t15k_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t15k_dir}/project" \
    HOOK_SESSION_PID="t15k_$$" \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || t15k_exit=$?

assert "t15k_old_config_error" \
  "echo '${t15k_stderr}' | grep -q 'subprocess.tiers'" \
  "error mentions migration to subprocess.tiers" \
  "no migration error for old config format"

# ============================================================================
# Test 1.5l: disallowedTools blacklist per tier
# ============================================================================
printf "\n--- test1.5l: disallowedTools blacklist per tier ---\n"

# Haiku tier allows Edit,Read — Bash,Write should be in disallowed list
assert "t15l_bash_blocked" \
  "grep -q 'Bash' '${t15a_args}' 2>/dev/null" \
  "Bash in disallowedTools for haiku" \
  "Bash NOT in disallowedTools for haiku"

assert "t15l_write_blocked" \
  "grep -q 'Write' '${t15a_args}' 2>/dev/null" \
  "Write in disallowedTools for haiku" \
  "Write NOT in disallowedTools for haiku"

# ============================================================================
# Test 1.5m: all tools allowed -> disallowedTools omitted, warning emitted
# ============================================================================
printf "\n--- test1.5m: all tools allowed (empty disallowedTools) ---\n"

ALL_TOOLS_CONFIG='{
  "phases": {"subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "SC[0-9]+", "tools": "Edit,Read,Write,Bash,Glob,Grep,WebFetch,WebSearch,NotebookEdit,Task", "max_turns": 10, "timeout": 120}
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}'

t15m_dir="${tmp_dir}/t15m"
mkdir -p "${t15m_dir}/bin"

t15m_args="${t15m_dir}/claude_args.txt"
cat >"${t15m_dir}/bin/claude" <<MOCK_EOF
#!/bin/bash
printf '%s\n' "\$@" > "${t15m_args}"
exit 0
MOCK_EOF
chmod +x "${t15m_dir}/bin/claude"

setup_project_dir "${t15m_dir}/project" "${ALL_TOOLS_CONFIG}"

t15m_file="${t15m_dir}/test.sh"
create_shell_file_with_violation "${t15m_file}"

t15m_json='{"tool_input":{"file_path":"'"${t15m_file}"'"}}'

export t15m_exit=0
t15m_stderr=$(echo "${t15m_json}" \
  | PATH="${t15m_dir}/bin:${PATH}" \
    CLAUDE_PROJECT_DIR="${t15m_dir}/project" \
    HOOK_SESSION_PID="t15m_$$" \
    bash "${hook_dir}/multi_linter.sh" 2>&1 >/dev/null) || t15m_exit=$?

assert "t15m_warning" \
  "echo '${t15m_stderr}' | grep -q '\\[hook:warning\\] all tools allowed'" \
  "warning emitted when all tools allowed" \
  "warning NOT emitted for empty disallowedTools"

assert "t15m_no_disallowed_flag" \
  "! grep -q -- '--disallowedTools' '${t15m_args}' 2>/dev/null" \
  "--disallowedTools omitted when empty" \
  "--disallowedTools present with empty value (should be omitted)"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
