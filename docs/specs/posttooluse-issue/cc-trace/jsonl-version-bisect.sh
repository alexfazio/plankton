#!/bin/bash
# jsonl_version_bisect.sh — PostToolUse output regression bisection
#
# Usage: ./jsonl_version_bisect.sh [project_dir...]
# Default: plankton + incide main project dirs

set -euo pipefail

# --- Configuration ---

PLANKTON_DIR="${HOME}/.claude/projects/-Users-alex-Documents-GitHub-plankton"
INCIDE_DIR="${HOME}/.claude/projects/-Users-alex-Documents-GitHub-incide"

# Finding C: correct array expansion for default dirs
if (($# > 0)); then
  PROJECT_DIRS=("$@")
else
  PROJECT_DIRS=("${PLANKTON_DIR}" "${INCIDE_DIR}")
fi

MIN_LINES=10 # Finding F: skip abandoned sessions

# Hook output patterns (regex for jaq)
export HOOK_PATTERN='\\[hook[:\\]]|violation\\(s\\) remain|hook error|blocking error|"decision".*"block"'
export SUCCESS_PATTERN='File created|updated successfully'

# Output files — Finding K: persistent evidence dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE_DIR="${SCRIPT_DIR}/jsonl-version-bisect"
mkdir -p "${EVIDENCE_DIR}"
MATRIX_FILE="${EVIDENCE_DIR}/matrix.tsv"
EVIDENCE_FILE="${EVIDENCE_DIR}/evidence.txt"
SUMMARY_FILE="${EVIDENCE_DIR}/summary.txt"

# --- Functions ---

extract_version() {
  local file="$1"
  jaq -r '.version // empty' "${file}" 2>/dev/null | sort -u | head -1
}

is_subprocess_session() {
  # Finding E: detect subprocess sessions (spawned by hooks)
  local file="$1"
  local first_user_msg
  first_user_msg=$(jaq -r '
    select(.type == "user") |
    if (.message.content | type) == "string" then .message.content
    elif (.message.content | type) == "array" then
      [.message.content[]? | select(.type == "text") | .text] | first // ""
    else "" end
  ' "${file}" 2>/dev/null | head -1)
  [[ "${first_user_msg}" == "You are a"* ]]
}

scan_session() {
  local file="$1"
  local version session_id line_count hooks_ran pretooluse_ev
  local hook_in_result sysreminder_match snippet

  # Finding F: skip tiny files
  line_count=$(wc -l <"${file}" | tr -d ' ')
  if ((line_count < MIN_LINES)); then
    return 1 # signal: skipped
  fi

  version=$(extract_version "${file}")
  [[ -z "${version}" ]] && version="UNKNOWN"
  session_id=$(basename "${file}" .jsonl)

  # Finding E: skip subprocess sessions
  # shellcheck disable=SC2310
  if is_subprocess_session "${file}"; then
    return 1 # signal: skipped
  fi

  # Finding A: correct progress event format (.data.hookEvent)
  local progress_hit
  progress_hit=$(jaq -r '
    select(.type == "progress") |
    select(.data?.hookEvent? == "PostToolUse") |
    .data.hookName
  ' "${file}" 2>/dev/null | head -1)
  [[ -n "${progress_hit}" ]] && hooks_ran="Y" || hooks_ran="N"

  # Finding D: mark N/A for pre-v2.1.9 (no progress events existed)
  if [[ "${hooks_ran}" == "N" ]]; then
    local has_any_progress
    has_any_progress=$(jaq -r 'select(.type == "progress") | .type' \
      "${file}" 2>/dev/null | head -1)
    [[ -z "${has_any_progress}" ]] && hooks_ran="N/A"
  fi

  # Finding G: PreToolUse control signal
  # Search for tool_results containing decision:block WITHOUT success msg
  local pre_hit
  # shellcheck disable=SC2016
  pre_hit=$(jaq -c '
    select(.type == "user") |
    select(.message.content | type == "array") |
    .message.content[]? |
    select(.type == "tool_result") |
    select(
      (if (.content | type) == "string" then .content else
        [.content[]? | select(.type == "text") | .text] | join("\n")
      end) as $c |
      ($c | test("\"decision\".*\"block\"")) and
      ($c | test("File created|updated successfully") | not)
    ) | .tool_use_id
  ' "${file}" 2>/dev/null | head -1)
  [[ -n "${pre_hit}" ]] && pretooluse_ev="Y" || pretooluse_ev="N"

  # Finding B: corrected tool_result search with schema guards
  # Bug fix: exclude Read tool results (line-numbered content: "  1→...")
  local match
  # shellcheck disable=SC2016
  match=$(jaq -c '
    select(.type == "user") |
    select(.message.content | type == "array") |
    .message.content[]? |
    select(.type == "tool_result") |
    (if (.content | type) == "string" then .content
     elif (.content | type) == "array" then
       [.content[]? | select(.type == "text") | .text] | join("\n")
     else "" end) as $c |
    select($c | test("^\\s*\\d+→") | not) |
    select($c | .[0:150] | test("File created|updated successfully")) |
    select($c | test("\\[hook[:\\]]|violation\\(s\\) remain|hook error|blocking error|\"decision\".*\"block\"")) |
    {tool_use_id, content: ($c | .[0:300])}
  ' "${file}" 2>/dev/null | head -1)

  if [[ -n "${match}" ]]; then
    hook_in_result="Y"
    snippet="${match}"
  else
    hook_in_result="N"
    snippet=""
  fi

  # Finding H: search system-reminder lines for hook patterns
  local sys_hit
  sys_hit=$(jaq -c '
    select(.type == "system") |
    .message?.content? // "" |
    if type == "string" then . else "" end |
    select(test("\\[hook[:\\]]|violation\\(s\\) remain|\"decision\".*\"block\""))
  ' "${file}" 2>/dev/null | head -1)
  [[ -n "${sys_hit}" ]] && sysreminder_match="Y" || sysreminder_match="N"

  # Bug fix 2: write TSV line directly to matrix file (not via shell redirect)
  printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\n" \
    "${version}" "${session_id}" "${line_count}" \
    "${hooks_ran}" "${pretooluse_ev}" "${hook_in_result}" "${sysreminder_match}" \
    >>"${MATRIX_FILE}"

  # Output evidence if any positive signal found
  if [[ "${hook_in_result}" == "Y" || "${sysreminder_match}" == "Y" ]]; then
    {
      echo "=== POSITIVE MATCH ==="
      echo "Version: ${version}"
      echo "Session: ${session_id}"
      echo "File: ${file}"
      echo "Lines: ${line_count}"
      echo "Channel: tool_result=${hook_in_result} sysreminder=${sysreminder_match}"
      echo "PreToolUse control: ${pretooluse_ev}"
      [[ -n "${snippet}" ]] && echo "Snippet: ${snippet}"
      [[ -n "${sys_hit}" ]] && echo "SysReminder: ${sys_hit}"
      echo ""
    } >>"${EVIDENCE_FILE}"
  fi
}

# --- Main ---

echo "VERSION BISECTION: PostToolUse Hook Output Regression"
echo "====================================================="
echo ""

: >"${MATRIX_FILE}"
: >"${EVIDENCE_FILE}"

skipped=0
scanned=0

# Scan all JSONL files
for dir in "${PROJECT_DIRS[@]}"; do
  echo "Scanning: ${dir}"
  for file in "${dir}"/*.jsonl; do
    [[ -f "${file}" ]] || continue
    # Bug fix 3: safe arithmetic under set -e
    scan_result=0
    # shellcheck disable=SC2310
    scan_session "${file}" || scan_result=$?
    if [[ ${scan_result} -eq 0 ]]; then
      scanned=$((scanned + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
done

echo ""
echo "Scanned: ${scanned} sessions, Skipped: ${skipped}"
echo ""
echo "--- Version Summary ---"
# Aggregate by version (Finding M: expanded columns)
sort -t$'\t' -k1,1V "${MATRIX_FILE}" \
  | awk -F'\t' '{
    v[$1]++
    if ($4=="Y") hr[$1]++
    if ($4=="N/A") na[$1]++
    if ($5=="Y") pre[$1]++
    if ($6=="Y") hir[$1]++
    if ($7=="Y") sr[$1]++
  } END {
    printf "%-10s %8s %9s %10s %9s %7s\n", \
      "VERSION", "SESSIONS", "HOOKS_RAN", "PRETOOLUSE", "IN_RESULT", "SYSREM"
    for (k in v) {
      hr_val = na[k]+0 > 0 ? "N/A" : hr[k]+0
      printf "%-10s %8d %9s %10d %9d %7d\n", \
        k, v[k], hr_val, pre[k]+0, hir[k]+0, sr[k]+0
    }
  }' | sort -t. -k1,1n -k2,2n -k3,3n | tee "${SUMMARY_FILE}"

echo ""
echo "Evidence: ${EVIDENCE_FILE}"
echo "Matrix:   ${MATRIX_FILE}"
echo "Summary:  ${SUMMARY_FILE}"

# Show evidence count
ev_count=$(grep -c "=== POSITIVE MATCH ===" "${EVIDENCE_FILE}" 2>/dev/null || true)
echo ""
echo "Positive matches found: ${ev_count}"
