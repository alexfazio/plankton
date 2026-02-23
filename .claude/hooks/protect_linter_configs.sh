#!/bin/bash
# protect_linter_configs.sh - Claude Code PreToolUse hook
# shellcheck disable=SC2310  # functions in if/|| is intentional
# Blocks modification of linter configuration files (defense layer 4)
#
# Protected files define code quality standards. Modifying them to make
# violations disappear (instead of fixing the code) is rule-gaming behavior.
#
# Output: JSON schema per PreToolUse spec
#   {"decision": "approve"} - Allow operation
#   {"decision": "block", "reason": "..."} - Block operation

set -euo pipefail

# Read JSON input from stdin
input=$(cat)

# Extract file path from tool_input
# If jaq fails (missing/crash), fail-open with valid JSON schema
file_path=$(jaq -r '.tool_input?.file_path? // empty' \
  <<<"${input}" 2>/dev/null) || {
  echo '{"decision": "approve"}'
  exit 0
}

# Skip if no file path (approve with valid JSON)
if [[ -z "${file_path}" ]]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Get basename for matching
basename=$(basename "${file_path}")

# Path-based protection for .claude/ directory
# Protects entire hooks directory and settings files
if [[ "${file_path}" == *"/.claude/hooks/"* ]] \
  || [[ "${file_path}" == *"/.claude/settings.json" ]] \
  || [[ "${file_path}" == *"/.claude/settings.local.json" ]]; then
  cat <<EOF
{"decision": "block", "reason": "Protected Claude Code config (${basename}). Hook scripts and settings are immutable."}
EOF
  exit 0
fi

# Load protected files from config, or use defaults
load_protected_files() {
  local config_file="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"
  if [[ -f "${config_file}" ]] && command -v jaq >/dev/null 2>&1; then
    local files
    files=$(jaq -r '.protected_files // [] | .[]' "${config_file}" 2>/dev/null)
    if [[ -n "${files}" ]]; then
      echo "${files}"
      return
    fi
  fi
  # Default protected files
  printf '%s\n' \
    ".markdownlint.jsonc" ".markdownlint-cli2.jsonc" ".shellcheckrc" \
    ".yamllint" ".hadolint.yaml" ".jscpd.json" ".flake8" \
    "taplo.toml" ".ruff.toml" "ty.toml" \
    "biome.json" ".oxlintrc.json" ".semgrep.yml" "knip.json"
}

# Check if basename matches a protected linter config file
is_protected_config() {
  local check_basename="$1"
  local protected_file
  while IFS= read -r protected_file; do
    [[ -z "${protected_file}" ]] && continue
    if [[ "${check_basename}" == "${protected_file}" ]]; then
      return 0
    fi
  done < <(load_protected_files || true)
  return 1
}

# Check if this is a protected linter config file
if is_protected_config "${basename}"; then
  cat <<EOF
{"decision": "block", "reason": "Protected linter config file (${basename}). Fix the code, not the rules."}
EOF
  exit 0
fi

# Not a protected file, allow operation
echo '{"decision": "approve"}'
exit 0
