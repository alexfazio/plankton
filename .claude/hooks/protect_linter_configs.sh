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

# Extract file path from tool_input (with notebook_path fallback)
# If jaq fails (missing/crash), fail-open with valid JSON schema
file_path=$(jaq -r '.tool_input?.file_path? // .tool_input?.notebook_path? // empty' \
  <<<"${input}" 2>/dev/null) || {
  echo '{"decision": "approve"}'
  exit 0
}

# Skip if no file path (approve with valid JSON)
if [[ -z "${file_path}" ]]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# The canonical hook test suite now lives under .claude/hooks/test/.
# Those files are intentionally editable and must not be treated as immutable
# hook infrastructure or protected linter configs.
is_hook_test_path() {
  local p="$1"
  if [[ "${p}" == ".claude/hooks/test/"* ]] || [[ "${p}" == *"/.claude/hooks/test/"* ]]; then return 0; fi
  return 1
}

if is_hook_test_path "${file_path}"; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Get basename for matching
basename=$(basename "${file_path}")

# Path-based protection for .claude/ directory
# Protects hooks directory, settings files, and subprocess settings
# Matches both relative (.claude/...) and absolute (*/.claude/...) paths
is_protected_claude_path() {
  local p="$1"
  # .claude/hooks/* (relative or absolute)
  if [[ "${p}" == ".claude/hooks/"* ]] || [[ "${p}" == *"/.claude/hooks/"* ]]; then return 0; fi
  # .claude/settings.json
  if [[ "${p}" == ".claude/settings.json" ]] || [[ "${p}" == *"/.claude/settings.json" ]]; then return 0; fi
  # .claude/settings.local.json
  if [[ "${p}" == ".claude/settings.local.json" ]] || [[ "${p}" == *"/.claude/settings.local.json" ]]; then return 0; fi
  # .claude/subprocess-settings.json
  if [[ "${p}" == ".claude/subprocess-settings.json" ]] || [[ "${p}" == *"/.claude/subprocess-settings.json" ]]; then return 0; fi
  return 1
}

if is_protected_claude_path "${file_path}"; then
  cat <<EOF
{"decision": "block", "reason": "Protected Claude Code config (${basename}). Hook scripts and settings are immutable."}
EOF
  exit 0
fi

# Portable path normalization (replaces GNU-only realpath -m)
# Tries: realpath (works on macOS/Linux for existing paths),
#         cd+pwd fallback (resolves symlinks in parent dir),
#         raw string (last resort)
_normalize_path() {
  local p="$1"
  realpath "${p}" 2>/dev/null && return 0
  # File doesn't exist — try resolving the parent directory
  local dir base
  dir="$(dirname "${p}")"
  base="$(basename "${p}")"
  if [[ -d "${dir}" ]]; then
    # shellcheck disable=SC2312  # intentional: inline cd+pwd for path resolution
    echo "$(cd "${dir}" && pwd)/${base}"
  else
    echo "${p}"
  fi
}

# Dynamic protection for config-specified subprocess settings file
protect_configured_settings() {
  local candidate="$1"
  local config_file="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"
  [[ -f "${config_file}" ]] || return 1
  command -v jaq >/dev/null 2>&1 || return 1

  local configured_path
  configured_path=$(jaq -r '.subprocess.settings_file // empty' "${config_file}" 2>/dev/null) || return 1
  [[ -z "${configured_path}" ]] && return 1

  # Expand leading tilde
  configured_path="${configured_path/#\~/${HOME}}"

  # Normalize both paths for comparison (portable)
  local norm_candidate norm_configured
  norm_candidate=$(_normalize_path "${candidate}")
  norm_configured=$(_normalize_path "${configured_path}")

  [[ "${norm_candidate}" == "${norm_configured}" ]]
}

if protect_configured_settings "${file_path}"; then
  cat <<EOF
{"decision": "block", "reason": "Protected subprocess settings file (${basename}). This file controls subprocess recursion safety."}
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
  # shellcheck disable=SC2312
  while IFS= read -r protected_file; do
    [[ -z "${protected_file}" ]] && continue
    if [[ "${check_basename}" == "${protected_file}" ]]; then
      return 0
    fi
  done < <(load_protected_files || true)
  return 1
}

# Check if this is a protected linter config file
# shellcheck disable=SC2310
if is_protected_config "${basename}"; then
  cat <<EOF
{"decision": "block", "reason": "Protected linter config file (${basename}). Fix the code, not the rules."}
EOF
  exit 0
fi

# Not a protected file, allow operation
echo '{"decision": "approve"}'
exit 0
