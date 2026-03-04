#!/bin/bash
# enforce_package_managers.sh - Claude Code PreToolUse hook (Bash matcher)
# Blocks legacy package managers and suggests project-preferred alternatives.
#   python:     pip/pip3/python -m pip/python -m venv/poetry/pipenv  → uv
#   javascript: npm/npx/yarn/pnpm                                    → bun
#
# Output: JSON per PreToolUse spec (always exit 0)
#   {"decision": "approve"}
#   {"decision": "block", "reason": "[hook:block] <tool> is not allowed. Use: <replacement>"}

set -euo pipefail

# Session-level bypass (HOOK_SKIP_PM=1 claude ...)
if [[ "${HOOK_SKIP_PM:-0}" == "1" ]]; then
  echo '{"decision": "approve"}'; exit 0
fi

input=$(cat)

# Extract command string; fail-open if jaq missing or input malformed
cmd=$(jaq -r '.tool_input?.command? // empty' <<<"${input}" 2>/dev/null) || {
  echo '{"decision": "approve"}'; exit 0
}
[[ -z "${cmd}" ]] && { echo '{"decision": "approve"}'; exit 0; }

# Strip heredoc content from cmd to avoid false positives.
# Heredoc bodies contain data (not commands) — PM enforcement
# should not match tool names found only inside heredoc text.
if [[ "${cmd}" == *'<<'* ]]; then
  cmd=$(printf '%s\n' "${cmd}" | awk '
    BEGIN { skip = 0 }
    skip {
      t = $0; gsub(/^[[:space:]]+/, "", t)
      if (t == delim) { skip = 0 }
      next
    }
    /<</ {
      s = $0; sub(/.*<<-?[[:space:]]*/, "", s)
      sub(/^["\047]/, "", s); sub(/["\047].*/, "", s)
      sub(/[[:space:]].*/, "", s)
      if (s != "") {
        delim = s; skip = 1
        sub(/[[:space:]]*<<.*/, "", $0)
        if ($0 != "") print
        next
      }
    }
    { print }
  ')
fi


config_file="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"

# get_pm_enforcement(lang) — reads .package_managers.<lang> from config
# Returns "uv", "uv:warn", "bun", "bun:warn", or "false"
get_pm_enforcement() {
  local lang="$1"
  jaq -r ".package_managers.${lang} // false" \
    "${config_file}" 2>/dev/null || echo "false"
}

# parse_pm_config(value) — splits value into mode+tool
# false     → "off"
# *:warn    → "warn:<tool>"
# *         → "block:<tool>"
parse_pm_config() {
  local value="$1"
  case "${value}" in
    false) echo "off" ;;
    *:warn) echo "warn:${value%:warn}" ;;
    *) echo "block:${value}" ;;
  esac
}

# ============================================================
# Compound Command Support (multi-tool replacement)
# ============================================================

# Global array to collect blocked PM violations across all segments
# Format: "tool:subcmd:segment_index"
BLOCKED_PMS=()
SEGMENTS_INFO=""
SEG_TOOL=""
SEG_SUBCMD=""

# reset_blocked_pms() — clear the violations array
reset_blocked_pms() {
  BLOCKED_PMS=()
}

# add_blocked_pm(tool, subcmd, segment_idx) — add a violation
add_blocked_pm() {
  local tool="$1"
  local subcmd="${2:-}"
  local segment_idx="${3:-0}"
  BLOCKED_PMS+=("${tool}:${subcmd}:${segment_idx}")
}

# has_blocked_pms() — returns 0 if any violations recorded
has_blocked_pms() {
  [[ ${#BLOCKED_PMS[@]} -gt 0 ]]
}

# split_by_and(cmd_str) — splits command by && delimiter
# Outputs: one segment per line with segment index prefix "idx:segment"
split_by_and() {
  local cmd_str="$1"
  echo "${cmd_str}" | awk -F '&&' '
    {
      for (i = 1; i <= NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        if ($i != "") print (i-1) ":" $i
      }
    }
  '
}

# is_allowed_subcommand(tool, subcmd) — checks allowlist in config
# Returns 0 if subcmd is in the allowed list, 1 otherwise
is_allowed_subcommand() {
  local tool="$1"
  local subcmd="$2"
  local allowed
  while IFS= read -r allowed; do
    [[ "${subcmd}" == "${allowed}" ]] && return 0
  done < <(jaq -r ".package_managers.allowed_subcommands.${tool} // [] | .[]" \
    "${config_file}" 2>/dev/null || true)
  return 1
}


# detect_blocked_pm_in_segment(segment) — checks one segment for blocked PMs
# Sets global: SEG_TOOL, SEG_SUBCMD
# Returns: 0 if blocked PM found, 1 if clean
# Note: Uses same patterns as main enforcement blocks for consistency
detect_blocked_pm_in_segment() {
  local segment="$1"
  SEG_TOOL=""
  SEG_SUBCMD=""

  # Word boundary patterns (same as main enforcement)
  local WB_START='(^|[^a-zA-Z0-9_])'
  local WB_END='([^a-zA-Z0-9_]|$)'

  # Check Python PMs
  if   [[ "${segment}" =~ ${WB_START}pip3?[[:space:]]+([a-zA-Z]+) ]]; then
    local subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310
    if ! is_allowed_subcommand "pip" "${subcmd}"; then
      SEG_TOOL="pip"; SEG_SUBCMD="${subcmd}"; return 0
    fi
  elif [[ "${segment}" =~ ${WB_START}pip3?[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    return 1  # diagnostic
  elif [[ "${segment}" =~ ${WB_START}pip3?${WB_END} ]]; then
    SEG_TOOL="pip"; SEG_SUBCMD=""; return 0
  fi

  if [[ "${segment}" =~ ${WB_START}python3?[[:space:]]+-m[[:space:]]+pip${WB_END} ]]; then
    SEG_TOOL="python -m pip"; SEG_SUBCMD=""; return 0
  fi
  if [[ "${segment}" =~ ${WB_START}python3?[[:space:]]+-m[[:space:]]+venv${WB_END} ]]; then
    SEG_TOOL="python -m venv"; SEG_SUBCMD=""; return 0
  fi

  # Check poetry
  if   [[ "${segment}" =~ ${WB_START}poetry[[:space:]]+([a-zA-Z]+) ]]; then
    local subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310
    if ! is_allowed_subcommand "poetry" "${subcmd}"; then
      SEG_TOOL="poetry"; SEG_SUBCMD="${subcmd}"; return 0
    fi
  elif [[ "${segment}" =~ ${WB_START}poetry[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    return 1
  elif [[ "${segment}" =~ ${WB_START}poetry${WB_END} ]]; then
    SEG_TOOL="poetry"; SEG_SUBCMD=""; return 0
  fi

  # Check pipenv
  if   [[ "${segment}" =~ ${WB_START}pipenv[[:space:]]+([a-zA-Z]+) ]]; then
    local subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310
    if ! is_allowed_subcommand "pipenv" "${subcmd}"; then
      SEG_TOOL="pipenv"; SEG_SUBCMD="${subcmd}"; return 0
    fi
  elif [[ "${segment}" =~ ${WB_START}pipenv[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    return 1
  elif [[ "${segment}" =~ ${WB_START}pipenv${WB_END} ]]; then
    SEG_TOOL="pipenv"; SEG_SUBCMD=""; return 0
  fi

  # Check npm
  if   [[ "${segment}" =~ ${WB_START}npm[[:space:]]+([a-zA-Z]+) ]]; then
    local subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310
    if ! is_allowed_subcommand "npm" "${subcmd}"; then
      SEG_TOOL="npm"; SEG_SUBCMD="${subcmd}"; return 0
    fi
  elif [[ "${segment}" =~ ${WB_START}npm[[:space:]]+-[^[:space:]]*[[:space:]]+([a-zA-Z]+) ]]; then
    local subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310
    if ! is_allowed_subcommand "npm" "${subcmd}"; then
      SEG_TOOL="npm"; SEG_SUBCMD="${subcmd}"; return 0
    fi
  elif [[ "${segment}" =~ ${WB_START}npm[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    return 1
  elif [[ "${segment}" =~ ${WB_START}npm[[:space:]]+-[^[:space:]]* ]]; then
    SEG_TOOL="npm"; SEG_SUBCMD=""; return 0
  elif [[ "${segment}" =~ ${WB_START}npm${WB_END} ]]; then
    SEG_TOOL="npm"; SEG_SUBCMD=""; return 0
  fi

  # Check npx
  if [[ "${segment}" =~ ${WB_START}npx[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    return 1
  elif [[ "${segment}" =~ ${WB_START}npx${WB_END} ]]; then
    SEG_TOOL="npx"; SEG_SUBCMD=""; return 0
  fi

  # Check yarn
  if   [[ "${segment}" =~ ${WB_START}yarn[[:space:]]+([a-zA-Z]+) ]]; then
    local subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310
    if ! is_allowed_subcommand "yarn" "${subcmd}"; then
      SEG_TOOL="yarn"; SEG_SUBCMD="${subcmd}"; return 0
    fi
  elif [[ "${segment}" =~ ${WB_START}yarn[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    return 1
  elif [[ "${segment}" =~ ${WB_START}yarn${WB_END} ]]; then
    SEG_TOOL="yarn"; SEG_SUBCMD="install"; return 0
  fi

  # Check pnpm
  if   [[ "${segment}" =~ ${WB_START}pnpm[[:space:]]+([a-zA-Z]+) ]]; then
    local subcmd="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2310
    if ! is_allowed_subcommand "pnpm" "${subcmd}"; then
      SEG_TOOL="pnpm"; SEG_SUBCMD="${subcmd}"; return 0
    fi
  elif [[ "${segment}" =~ ${WB_START}pnpm[[:space:]]+(--version|-[vVh]|--help)${WB_END} ]]; then
    return 1
  elif [[ "${segment}" =~ ${WB_START}pnpm${WB_END} ]]; then
    SEG_TOOL="pnpm"; SEG_SUBCMD="install"; return 0
  fi

  return 1  # No blocked PM found
}



# compute_segment_replacement(segment, tool, subcmd) — replacement for ONE segment
# Uses segment text instead of global ${cmd} for package extraction
compute_segment_replacement() {
  local segment="$1"
  local tool="$2"
  local subcmd="${3:-}"
  
  if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
    echo "[hook:debug] compute_segment_replacement: segment='${segment}', tool='${tool}', subcmd='${subcmd}'" >&2
  fi

  case "${tool}:${subcmd}" in
    pip:install|pip3:install)
      if echo "${segment}" | grep -qE '[[:space:]]-r([[:space:]]|[^[:space:]-])'; then
        local req_file
        req_file=$(echo "${segment}" | sed -nE           's/.*[[:space:]]-r[[:space:]]*([^[:space:]-][^[:space:]]*).*//p')
        echo "uv pip install -r ${req_file:-requirements.txt}"
      elif echo "${segment}" | grep -qE ' -e '; then
        echo "uv pip install -e ."
      else
        local pkgs
        pkgs=$(echo "${segment}" | sed -nE 's/.*pip3?[[:space:]]+install[[:space:]]+([^-].*)/\1/p' |           sed 's/[[:space:]]*$//')
        if [[ -n "${pkgs}" ]]; then
          echo "uv add ${pkgs}"
        else
          echo "uv add <packages>"
        fi
      fi
      ;;
    pip:uninstall|pip3:uninstall)
      local pkgs
      pkgs=$(echo "${segment}" | sed -nE 's/.*pip3?[[:space:]]+uninstall[[:space:]]+([^-].*)/\1/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "uv remove ${pkgs}"
      else
        echo "uv remove <packages>"
      fi
      ;;
    pip:freeze|pip3:freeze) echo "uv pip freeze" ;;
    pip:list|pip3:list)     echo "uv pip list" ;;
    pip:*|pip3:*)           echo "uv <equivalent>" ;;
    "python -m pip":*)      echo "uv add <packages>" ;;
    "python -m venv":*)
      local venv_dir
      venv_dir=$(echo "${segment}" | sed -nE 's/.*python3?[[:space:]]+-m[[:space:]]+venv[[:space:]]+([^[:space:]]+).*/\1/p')
      if [[ -n "${venv_dir}" ]]; then
        echo "uv venv ${venv_dir}"
      else
        echo "uv venv"
      fi
      ;;
    poetry:add)
      local pkgs
      pkgs=$(echo "${segment}" | sed -nE 's/.*poetry[[:space:]]+add[[:space:]]+(.+)/\1/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "uv add ${pkgs}"
      else
        echo "uv add <packages>"
      fi
      ;;
    poetry:install)   echo "uv sync" ;;
    poetry:run)
      local run_cmd
      run_cmd=$(echo "${segment}" | sed -nE 's/.*poetry[[:space:]]+run[[:space:]]+(.+)/\1/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${run_cmd}" ]]; then
        echo "uv run ${run_cmd}"
      else
        echo "uv run <cmd>"
      fi
      ;;
    poetry:lock)      echo "uv lock" ;;
    poetry:*)         echo "uv <equivalent>" ;;
    pipenv:install)
      local pkgs
      pkgs=$(echo "${segment}" | sed -nE 's/.*pipenv[[:space:]]+install[[:space:]]+([^-].*)/\1/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "uv add ${pkgs}"
      else
        echo "uv sync"
      fi
      ;;
    pipenv:run)
      local run_cmd
      run_cmd=$(echo "${segment}" | sed -nE 's/.*pipenv[[:space:]]+run[[:space:]]+(.+)/\1/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${run_cmd}" ]]; then
        echo "uv run ${run_cmd}"
      else
        echo "uv run <cmd>"
      fi
      ;;
    pipenv:*)         echo "uv <equivalent>" ;;
    npm:install|npm:i|npm:ci)
      local pkgs
      pkgs=$(echo "${segment}" | sed -nE 's/.*npm[[:space:]]+(install|i|ci)[[:space:]]+([^-].*)/\2/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun add ${pkgs}"
      else
        echo "bun install"
      fi
      ;;
    npm:run)
      local script
      script=$(echo "${segment}" | sed -nE 's/.*npm[[:space:]]+run[[:space:]]+([^[:space:]]+).*/\1/p')
      if [[ -n "${script}" ]]; then
        echo "bun run ${script}"
      else
        echo "bun run <script>"
      fi
      ;;
    npm:test)         echo "bun test" ;;
    npm:start)        echo "bun run start" ;;
    npm:exec)         echo "bunx <pkg>" ;;
    npm:init)         echo "bun init" ;;
    npm:uninstall|npm:remove)
      local pkgs
      pkgs=$(echo "${segment}" | sed -nE 's/.*npm[[:space:]]+(uninstall|remove)[[:space:]]+([^-].*)/\2/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun remove ${pkgs}"
      else
        echo "bun remove <packages>"
      fi
      ;;
    npm:*)            echo "bun <equivalent>" ;;
    npx:*)
      local pkg
      pkg=$(echo "${segment}" | sed -E 's/.*npx[[:space:]]+//' |         tr ' ' '
' | grep -v '^-' | head -1)
      if [[ -n "${pkg}" ]]; then
        echo "bunx ${pkg}"
      else
        echo "bunx <pkg>"
      fi
      ;;
    yarn:add)
      local pkgs
      pkgs=$(echo "${segment}" | sed -nE 's/.*yarn[[:space:]]+add[[:space:]]+([^-].*)/\1/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun add ${pkgs}"
      else
        echo "bun add <packages>"
      fi
      ;;
    yarn:install)     echo "bun install" ;;
    yarn:run)
      local script
      script=$(echo "${segment}" | sed -nE 's/.*yarn[[:space:]]+run[[:space:]]+([^[:space:]]+).*/\1/p')
      if [[ -n "${script}" ]]; then
        echo "bun run ${script}"
      else
        echo "bun run <script>"
      fi
      ;;
    yarn:remove)
      local pkgs
      pkgs=$(echo "${segment}" | sed -nE 's/.*yarn[[:space:]]+remove[[:space:]]+([^-].*)/\1/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun remove ${pkgs}"
      else
        echo "bun remove <packages>"
      fi
      ;;
    yarn:*)           echo "bun <equivalent>" ;;
    pnpm:add)
      local pkgs
      pkgs=$(echo "${segment}" | sed -nE 's/.*pnpm[[:space:]]+add[[:space:]]+([^-].*)/\1/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun add ${pkgs}"
      else
        echo "bun add <packages>"
      fi
      ;;
    pnpm:install)     echo "bun install" ;;
    pnpm:run)
      local script
      script=$(echo "${segment}" | sed -nE 's/.*pnpm[[:space:]]+run[[:space:]]+([^[:space:]]+).*/\1/p')
      if [[ -n "${script}" ]]; then
        echo "bun run ${script}"
      else
        echo "bun run <script>"
      fi
      ;;
    pnpm:remove)
      local pkgs
      pkgs=$(echo "${segment}" | sed -nE 's/.*pnpm[[:space:]]+(remove|uninstall)[[:space:]]+([^-].*)/\2/p' |         sed 's/[[:space:]]*$//')
      if [[ -n "${pkgs}" ]]; then
        echo "bun remove ${pkgs}"
      else
        echo "bun remove <packages>"
      fi
      ;;
    pnpm:*)           echo "bun <equivalent>" ;;
    *)                echo "use the project-preferred tool" ;;
  esac
}

# check_replacement_tool(tool, install_hint) — warns once per session if tool missing
check_replacement_tool() {
  local tool="$1"
  local install_hint="$2"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    local marker="/tmp/.pm_warn_${tool}_${HOOK_GUARD_PID:-${PPID}}"
    if [[ ! -f "${marker}" ]]; then
      echo "[hook:warning] ${tool} not found — blocked but replacement unavailable. Install: ${install_hint}" >&2
      touch "${marker}" 2>/dev/null || true
    fi
  fi
}

# approve() — log if debug/log, output approve JSON, exit 0
approve() {
  if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
    echo "[hook:debug] PM check: command='${cmd}', action='approve'" >&2
  fi
  if [[ "${HOOK_LOG_PM:-0}" == "1" ]]; then
    local log_file="/tmp/.pm_enforcement_${HOOK_GUARD_PID:-${PPID}}.log"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | approve | | | ${cmd:0:80}" >> "${log_file}" 2>/dev/null || true
  fi
  echo '{"decision": "approve"}'
  exit 0
}

# ============================================================
# Compound Command Functions (multi-tool replacement)
# ============================================================

# build_compound_replacement(segments_info) — builds full replacement command
# Iterates through segments, replacing blocked ones, preserving safe ones
build_compound_replacement() {
  local segments_info="$1"
  local result=()
  local line segment_idx segment
  
  if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
    echo "[hook:debug] build_compound_replacement: segments_info='${segments_info}'" >&2
  fi

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    segment_idx="${line%%:*}"
    segment="${line#*:}"

    # Check if this segment has a blocked PM
    local found=false
    local entry e_tool e_rest e_subcmd e_idx replacement

    for entry in "${BLOCKED_PMS[@]}"; do
      e_tool="${entry%%:*}"
      e_rest="${entry#*:}"
      e_subcmd="${e_rest%%:*}"
      e_idx="${e_rest##*:}"
      
      if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
        echo "[hook:debug] checking entry='${entry}', e_tool='${e_tool}', e_subcmd='${e_subcmd}', e_idx='${e_idx}', segment_idx='${segment_idx}'" >&2
      fi

      if [[ "${e_idx}" == "${segment_idx}" ]]; then
        # This segment was blocked - generate replacement
        replacement=$(compute_segment_replacement "${segment}" "${e_tool}" "${e_subcmd}")
        if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
          echo "[hook:debug] replacement='${replacement}' for segment='${segment}', tool='${e_tool}', subcmd='${e_subcmd}'" >&2
        fi
        result+=("${replacement}")
        found=true
        break
      fi
    done

    if ! "${found}"; then
      # No blocked PM in this segment - keep original
      result+=("${segment}")
    fi
  done <<< "${segments_info}"

  # Join with &&
  local first=true
  for r in "${result[@]}"; do
    if "${first}"; then
      printf '%s' "${r}"
      first=false
    else
      printf ' && %s' "${r}"
    fi
  done
}

# get_tools_list() — builds comma-separated list of blocked tools
get_tools_list() {
  local tools_list=""
  local entry tool
  for entry in "${BLOCKED_PMS[@]}"; do
    tool="${entry%%:*}"
    if [[ -z "${tools_list}" ]]; then
      tools_list="${tool}"
    elif [[ "${tools_list}" != *"${tool}"* ]]; then
      tools_list="${tools_list}, ${tool}"
    fi
  done
  echo "${tools_list}"
}

# block_compound(segments_info) — block with compound replacement message
block_compound() {
  local segments_info="$1"
  local full_replacement tools_list

  full_replacement=$(build_compound_replacement "${segments_info}")
  tools_list=$(get_tools_list)

  if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
    echo "[hook:debug] PM check: command='${cmd}', action='block_compound', tools='${tools_list}'" >&2
  fi
  if [[ "${HOOK_LOG_PM:-0}" == "1" ]]; then
    local log_file="/tmp/.pm_enforcement_${HOOK_GUARD_PID:-${PPID}}.log"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | block_compound | ${tools_list} | | ${cmd:0:80}" >> "${log_file}" 2>/dev/null || true
  fi

  echo "{\"decision\": \"block\", \"reason\": \"[hook:block] ${tools_list} not allowed. Use: ${full_replacement}\"}"
  exit 0
}

# warn_compound(segments_info) — warn with compound advisory message
warn_compound() {
  local segments_info="$1"
  local full_replacement tools_list

  full_replacement=$(build_compound_replacement "${segments_info}")
  tools_list=$(get_tools_list)

  if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
    echo "[hook:debug] PM check: command='${cmd}', action='warn_compound', tools='${tools_list}'" >&2
  fi
  if [[ "${HOOK_LOG_PM:-0}" == "1" ]]; then
    local log_file="/tmp/.pm_enforcement_${HOOK_GUARD_PID:-${PPID}}.log"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | warn_compound | ${tools_list} | | ${cmd:0:80}" >> "${log_file}" 2>/dev/null || true
  fi

  echo '{"decision": "approve"}'
  echo "[hook:advisory] ${tools_list} detected. Prefer: ${full_replacement}" >&2
  exit 0
}

# scan_compound_command() — scans entire command for all blocked PMs
# Returns: 0 if any blocked PMs found, 1 if command is clean
# Sets: BLOCKED_PMS array, SEGMENTS_INFO for later use
scan_compound_command() {
  reset_blocked_pms
  SEGMENTS_INFO=""

  # Get config modes
  local py_raw js_raw py_mode js_mode
  py_raw=$(get_pm_enforcement "python")
  py_mode=$(parse_pm_config "${py_raw}"); py_mode="${py_mode%%:*}"
  js_raw=$(get_pm_enforcement "javascript")
  js_mode=$(parse_pm_config "${js_raw}"); js_mode="${js_mode%%:*}"

  # If both off, nothing to do
  [[ "${py_mode}" == "off" && "${js_mode}" == "off" ]] && return 1

  # Split command by &&
  SEGMENTS_INFO=$(split_by_and "${cmd}")
  [[ -z "${SEGMENTS_INFO}" ]] && return 1

  local line segment_idx segment
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    segment_idx="${line%%:*}"
    segment="${line#*:}"

    # Check for uv/bun passthrough first (these approve the whole command)
    if [[ "${py_mode}" != "off" && "${segment}" =~ (^|[^a-zA-Z0-9_])uv[[:space:]] ]]; then
      continue  # uv passthrough - this segment is OK
    fi
    if [[ "${js_mode}" != "off" && "${segment}" =~ (^|[^a-zA-Z0-9_])bun[[:space:]] ]]; then
      continue  # bun passthrough - this segment is OK
    fi

    # Check for blocked PM in this segment
    # shellcheck disable=SC2310
    if detect_blocked_pm_in_segment "${segment}"; then
      # Determine if this tool is under enforcement
      local is_python_tool=false is_js_tool=false
      case "${SEG_TOOL}" in
        pip|pip3|poetry|pipenv|"python -m pip"|"python -m venv") is_python_tool=true ;;
        npm|npx|yarn|pnpm) is_js_tool=true ;;
      *) ;;  # other tools not under enforcement
      esac

      # Only add if enforcement is enabled for this ecosystem
      if "${is_python_tool}" && [[ "${py_mode}" != "off" ]]; then
        add_blocked_pm "${SEG_TOOL}" "${SEG_SUBCMD}" "${segment_idx}"
      elif "${is_js_tool}" && [[ "${js_mode}" != "off" ]]; then
        add_blocked_pm "${SEG_TOOL}" "${SEG_SUBCMD}" "${segment_idx}"
      fi
    fi
  done <<< "${SEGMENTS_INFO}"

  has_blocked_pms
}

# ============================================================
# Main Execution Flow (two-phase compound-aware approach)
# ============================================================

# Word boundary patterns (used for passthrough checks)
WB_START='(^|[^a-zA-Z0-9_])'
WB_END='([^a-zA-Z0-9_]|$)'

# Get config modes for mode determination
py_raw=$(get_pm_enforcement "python")
py_parsed=$(parse_pm_config "${py_raw}")
py_mode="${py_parsed%%:*}"   # off / warn / block
js_raw=$(get_pm_enforcement "javascript")
js_parsed=$(parse_pm_config "${js_raw}")
js_mode="${js_parsed%%:*}"   # off / warn / block

# Special case: uv pip passthrough approves entire command (known limitation)
if [[ "${py_mode}" != "off" && "${cmd}" =~ ${WB_START}uv[[:space:]]+pip ]]; then
  approve
fi

# Phase 1: Scan for ALL blocked PMs across entire compound command
# shellcheck disable=SC2310  # intentional: capture exit code under set -e
  scan_compound_command && scan_result=0 || scan_result=$?
if [[ "${HOOK_DEBUG_PM:-0}" == "1" ]]; then
  echo "[hook:debug] scan_result=${scan_result}, BLOCKED_PMS count=${#BLOCKED_PMS[@]}" >&2
fi
if [[ ${scan_result} -eq 0 ]]; then
  if [[ ${#BLOCKED_PMS[@]} -gt 0 ]]; then
    # Determine mode based on first blocked tool
    first_entry="${BLOCKED_PMS[0]}"
    first_tool="${first_entry%%:*}"
    mode="block"

    case "${first_tool}" in
      pip|pip3|poetry|pipenv|"python -m pip"|"python -m venv")
        mode="${py_mode}"
        check_replacement_tool "uv" "brew install uv"
        ;;
      npm|npx|yarn|pnpm)
        mode="${js_mode}"
        check_replacement_tool "bun" "curl -fsSL https://bun.sh/install | bash"
        ;;
    *) mode="block" ;;  # default to block
    esac

    if [[ "${mode}" == "warn" ]]; then
      warn_compound "${SEGMENTS_INFO}"
    else
      block_compound "${SEGMENTS_INFO}"
    fi
  fi
fi

# No blocked PMs found - approve
approve
