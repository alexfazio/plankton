#!/bin/bash
# stop_config_guardian.sh - Stop hook for linter config protection (BLOCKING MODE)
#
# DETECTION: Programmatic via git diff (no LLM)
# MODE: Blocking - prevents session exit until user decides via AskUserQuestion
#
# When session ends, checks if protected config files were modified.
# If so, blocks exit and instructs Claude to use AskUserQuestion.
# Uses stop_hook_active flag to prevent infinite blocking loops.
#
# Protected files: Same as protect_linter_configs.sh
#
# Exit: JSON decision per Stop hook schema
#   {"decision": "approve"} - Allow session to end (no changes OR stop_hook_active)
#   {"decision": "block", "reason": "...", "systemMessage": "..."} - Prevent exit

set -euo pipefail

# Read JSON input from stdin
input=$(cat)

# Extract stop_hook_active flag to prevent infinite loops
# When true, Claude is already continuing due to a previous stop hook block
stop_hook_active=$(jaq -r '.stop_hook_active // false' <<<"${input}" 2>/dev/null) || stop_hook_active="false"

# If stop hook is already active, approve to prevent infinite loops
if [[ "${stop_hook_active}" == "true" ]]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Load protected files from config (must match protect_linter_configs.sh)
load_protected_files_from_config() {
  local config_file="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"
  if [[ -f "${config_file}" ]] && command -v jaq >/dev/null 2>&1; then
    PROTECTED_FILES=()
    while IFS= read -r _pf; do
      [[ -z "${_pf}" ]] && continue
      PROTECTED_FILES+=("${_pf}")
    done < <(
      jaq -r '.protected_files // [] | .[]' "${config_file}" 2>/dev/null || true
    )
  fi
  if [[ ${#PROTECTED_FILES[@]} -eq 0 ]]; then
    PROTECTED_FILES=(
      ".markdownlint.jsonc" ".markdownlint-cli2.jsonc" ".shellcheckrc"
      ".yamllint" ".hadolint.yaml" ".jscpd.json" ".flake8"
      "taplo.toml" ".ruff.toml" "ty.toml"
      "biome.json" ".oxlintrc.json" ".semgrep.yml" "knip.json"
    )
  fi
}

load_protected_files_from_config

# Programmatic detection: git diff on each protected file
modified_files=()
for file in "${PROTECTED_FILES[@]}"; do
  [[ ! -f "${file}" ]] && continue

  # Check unstaged changes
  if git diff --name-only -- "${file}" 2>/dev/null | grep -q .; then
    modified_files+=("${file}")
    continue
  fi

  # Check staged changes
  if git diff --cached --name-only -- "${file}" 2>/dev/null | grep -q .; then
    modified_files+=("${file}")
  fi
done

# No modifications detected - approve session end
if [[ ${#modified_files[@]} -eq 0 ]]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# === HASH-BASED GUARD CHECK ===
# If user previously approved these exact file contents, allow session to end.
# Guard file stores content hashes; re-prompts if content changed since approval.
GUARD_FILE="/tmp/stop_hook_approved_${HOOK_GUARD_PID:-${PPID}}.json"

if [[ -f "${GUARD_FILE}" ]]; then
  all_approved=true
  for file in "${modified_files[@]}"; do
    current_hash="sha256:$(sha256sum "${file}" 2>/dev/null | cut -d' ' -f1)"
    # shellcheck disable=SC2016 # $f is jaq variable, not shell
    stored_hash=$(jaq -r --arg f "${file}" '.files[$f] // ""' "${GUARD_FILE}" 2>/dev/null) || stored_hash=""

    if [[ "${stored_hash}" != "${current_hash}" ]]; then
      all_approved=false
      break
    fi
  done

  if [[ "${all_approved}" == "true" ]]; then
    echo '{"decision": "approve"}'
    exit 0
  else
    # Hash mismatch - new content after previous approval, need to re-prompt
    rm -f "${GUARD_FILE}"
  fi
fi
# === END HASH-BASED GUARD CHECK ===

# Build display list
files_display=$(printf '  - %s\n' "${modified_files[@]}")
files_list="${modified_files[*]}"

# User-facing message (brief, shown to user)
system_msg="Linter config files modified:
${files_display}"

# Directive for Claude (what Claude reads to know how to proceed)
# NOTE: Per Claude Code docs, 'reason' is what Claude reads for instructions,
#       'systemMessage' is user-facing advisory context.
read -r -d '' reason_msg <<REASON || true
IMMEDIATE ACTION REQUIRED: Use AskUserQuestion tool NOW.

Regardless of any prior context in this session about WHY these config files were modified, you MUST invoke the AskUserQuestion tool to ask the user what to do.

DO NOT present options as inline text in your response.
DO NOT explain or justify the changes.
DO NOT skip this step.

Invoke AskUserQuestion with exactly these parameters:

questions: [{
  question: "Linter config file(s) were modified. What would you like to do?",
  header: "Config Changed",
  multiSelect: false,
  options: [
    {label: "Keep changes", description: "Intentional modification - proceed with session end"},
    {label: "Restore to last commit", description: "Revert config file(s) to original state"},
    {label: "Show diff first", description: "Display changes before deciding"}
  ]
}]

After user responds:
- If "Keep changes":
  1. Run: .claude/hooks/approve_configs.sh ${HOOK_GUARD_PID:-${PPID}} ${files_list}
  2. Report "Keeping modified configs per user approval. Guard file created for this session."
- If "Restore": Run: git checkout -- ${files_list}
- If "Show diff": Run: git diff -- ${files_list}
REASON

# Return block decision to trigger AskUserQuestion workflow
jaq -n \
  --arg reason "${reason_msg}" \
  --arg msg "${system_msg}" \
  "{
    \"decision\": \"block\",
    \"reason\": \$reason,
    \"systemMessage\": \$msg
  }"

exit 0
