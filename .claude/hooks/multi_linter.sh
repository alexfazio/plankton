#!/bin/bash
# shellcheck disable=SC2310  # functions in if/|| is intentional throughout
# multi_linter.sh - Claude Code PostToolUse hook for multi-language linting
# Supports: Python (ruff+ty+flake8-pydantic+flake8-async), Shell (shellcheck+shfmt),
#           YAML (yamllint), JSON (jaq/biome), Dockerfile (hadolint),
#           TOML (taplo), Markdown (markdownlint-cli2),
#           TypeScript/JS/CSS (biome+semgrep)
#
# Three-Phase Architecture:
#   Phase 1: Auto-format files (silent on success)
#   Phase 2: Collect unfixable violations as JSON
#   Phase 3: Delegate to claude subprocess for fixes, then verify
#
# Dependencies:
#   Required: jaq (JSON parsing), ruff (Python), claude (subprocess delegation)
#   Optional: shellcheck, shfmt, yamllint, hadolint, taplo, markdownlint-cli2,
#             ty (type checking), flake8-pydantic, biome (TypeScript/JS/CSS),
#             semgrep (security scanning)
#
# Project configs: .ruff.toml, ty.toml, taplo.toml, .yamllint,
#                  .shellcheckrc, .hadolint.yaml, .markdownlint.jsonc,
#                  biome.json, .semgrep.yml
#
# Exit Code Strategy:
#   0 - No issues or all issues fixed by delegation
#   2 - Issues remain after delegation attempt

set -euo pipefail

# Ensure Python venv tools are discoverable (uv sync installs to .venv/bin/)
# On macOS tools are on PATH via brew; on Linux they're only in the venv.
if [[ -d "${CLAUDE_PROJECT_DIR:-.}/.venv/bin" ]]; then
  export PATH="${CLAUDE_PROJECT_DIR:-.}/.venv/bin:${PATH}"
fi

trap 'kill 0' SIGTERM

# Output JSON to stdout for Claude Code hook protocol.
# PostToolUse hooks should return {"continue":true,"systemMessage":"..."}.
# Called at meaningful exit points (post-linting) — early bail-outs skip this.
# shellcheck disable=SC2329  # Called at exit points (wiring in progress)
hook_json() {
  local msg="${1:-}"
  if [[ -n "${msg}" ]]; then
    # shellcheck disable=SC2016 # $m is a jaq variable, not shell
    jaq -n --arg m "${msg}" '{"continue":true,"systemMessage":$m}' 2>/dev/null || printf '{"continue":true}\n'
  else
    printf '{"continue":true}\n'
  fi
}

# Emit JSON and exit clean — ensures Claude Code always receives valid JSON.
# shellcheck disable=SC2329  # invoked indirectly
exit_json() {
  hook_json "${1:-}"
  exit 0
}

# Emit structured timing diagnostics to stderr and, optionally, to a file.
# Never writes to stdout. Fail-open by design.
hook_diag() {
  local line="[hook:timing] t=${SECONDS} $*"
  printf '%s\n' "${line}" >&2
  if [[ -n "${HOOK_TIMING_LOG_FILE:-}" ]]; then
    local _log_dir
    _log_dir=$(dirname "${HOOK_TIMING_LOG_FILE}")
    mkdir -p "${_log_dir}" 2>/dev/null || true
    printf '%s\n' "${line}" >>"${HOOK_TIMING_LOG_FILE}" 2>/dev/null || true
  fi
}

# Fail-open if jaq is not installed (required for JSON parsing)
if ! command -v jaq >/dev/null 2>&1; then
  echo "[hook] error: jaq is required but not found. Install: brew install jaq" >&2
  printf '{"continue":true}\n'
  exit 0
fi

# ============================================================================
# CONFIGURATION LOADING
# Session PID for temp file scoping (override with HOOK_SESSION_PID for testing)
SESSION_PID="${HOOK_SESSION_PID:-${PPID}}"
# ============================================================================

# Load configuration from config.json (falls back to all-enabled if missing)
load_config() {
  local config_file="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/config.json"
  if [[ -f "${config_file}" ]]; then
    CONFIG_JSON=$(cat "${config_file}")
  else
    CONFIG_JSON='{}'
  fi
}

# Check if a language is enabled (default: true when missing)
is_language_enabled() {
  local lang="$1"
  local enabled
  enabled=$(echo "${CONFIG_JSON}" | jaq -r ".languages.${lang}" 2>/dev/null)
  [[ "${enabled}" != "false" ]]
}

# Get security-linter exclusion patterns from config (defaults if not configured).
# Backward compatible: prefer security_linter_exclusions, fall back to legacy
# exclusions if present.
get_security_linter_exclusions() {
  local defaults='[".venv/","node_modules/",".git/"]'
  echo "${CONFIG_JSON}" | jaq -r ".security_linter_exclusions // .exclusions // ${defaults} | .[]" 2>/dev/null
}

# Detect and reject old flat config format
check_config_migration() {
  local has_old_timeout has_old_model_selection
  has_old_timeout=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.timeout // empty' 2>/dev/null) || true
  has_old_model_selection=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.model_selection // empty' 2>/dev/null) || true
  # Only error if old keys exist AND new tiers key does NOT exist
  local has_tiers
  has_tiers=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers // empty' 2>/dev/null) || true
  if [[ -n "${has_old_timeout}" || -n "${has_old_model_selection}" ]] && [[ -z "${has_tiers}" ]]; then
    echo "[hook:error] config.json uses deprecated flat subprocess format." >&2
    echo "[hook:error] Migrate to subprocess.tiers structure. See docs/specs/subprocess-permission-gap.md" >&2
    return 1
  fi
}

# Load model selection patterns from config (tier-based or legacy defaults)
load_model_patterns() {
  local default_haiku='E[0-9]+|W[0-9]+|F[0-9]+|B[0-9]+|S[0-9]+|T[0-9]+|N[0-9]+|UP[0-9]+|YTT[0-9]+|ANN[0-9]+|BLE[0-9]+|FBT[0-9]+|A[0-9]+|COM[0-9]+|DTZ[0-9]+|EM[0-9]+|EXE[0-9]+|ISC[0-9]+|ICN[0-9]+|G[0-9]+|INP[0-9]+|PIE[0-9]+|PYI[0-9]+|PT[0-9]+|Q[0-9]+|RSE[0-9]+|RET[0-9]+|SLF[0-9]+|SIM[0-9]+|TID[0-9]+|TCH[0-9]+|INT[0-9]+|ARG[0-9]+|PTH[0-9]+|TD[0-9]+|FIX[0-9]+|ERA[0-9]+|PD[0-9]+|PGH[0-9]+|PLC[0-9]+|PLE[0-9]+|PLW[0-9]+|TRY[0-9]+|FLY[0-9]+|NPY[0-9]+|AIR[0-9]+|PERF[0-9]+|FURB[0-9]+|LOG[0-9]+|RUF[0-9]+|SC[0-9]+|DL[0-9]+|I[0-9]+'
  local default_sonnet='C901|PLR[0-9]+|PYD[0-9]+|FAST[0-9]+|ASYNC[0-9]+|unresolved-import|MD[0-9]+|D[0-9]+'
  local default_opus='unresolved-attribute|type-assertion'

  # Read from tiers structure (preferred) or fall back to defaults
  HAIKU_CODE_PATTERN=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.haiku.patterns // empty' 2>/dev/null) || true
  [[ -z "${HAIKU_CODE_PATTERN}" ]] && HAIKU_CODE_PATTERN="${default_haiku}"
  SONNET_CODE_PATTERN=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.sonnet.patterns // empty' 2>/dev/null) || true
  [[ -z "${SONNET_CODE_PATTERN}" ]] && SONNET_CODE_PATTERN="${default_sonnet}"
  OPUS_CODE_PATTERN=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.opus.patterns // empty' 2>/dev/null) || true
  [[ -z "${OPUS_CODE_PATTERN}" ]] && OPUS_CODE_PATTERN="${default_opus}"

  VOLUME_THRESHOLD=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.volume_threshold // empty' 2>/dev/null) || true
  [[ -z "${VOLUME_THRESHOLD}" ]] && VOLUME_THRESHOLD=5

  # Cross-tier overrides (env var takes precedence for timeout)
  GLOBAL_MODEL_OVERRIDE=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.global_model_override // empty' 2>/dev/null) || true
  MAX_TURNS_OVERRIDE=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.max_turns_override // empty' 2>/dev/null) || true
  TIMEOUT_OVERRIDE=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.timeout_override // empty' 2>/dev/null) || true
  [[ -n "${HOOK_SUBPROCESS_TIMEOUT:-}" ]] && TIMEOUT_OVERRIDE="${HOOK_SUBPROCESS_TIMEOUT}"

  # Per-tier max_turns and timeout
  HAIKU_MAX_TURNS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.haiku.max_turns // empty' 2>/dev/null) || true
  [[ -z "${HAIKU_MAX_TURNS}" ]] && HAIKU_MAX_TURNS=10
  SONNET_MAX_TURNS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.sonnet.max_turns // empty' 2>/dev/null) || true
  [[ -z "${SONNET_MAX_TURNS}" ]] && SONNET_MAX_TURNS=10
  OPUS_MAX_TURNS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.opus.max_turns // empty' 2>/dev/null) || true
  [[ -z "${OPUS_MAX_TURNS}" ]] && OPUS_MAX_TURNS=15

  HAIKU_TIMEOUT=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.haiku.timeout // empty' 2>/dev/null) || true
  [[ -z "${HAIKU_TIMEOUT}" ]] && HAIKU_TIMEOUT=120
  SONNET_TIMEOUT=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.sonnet.timeout // empty' 2>/dev/null) || true
  [[ -z "${SONNET_TIMEOUT}" ]] && SONNET_TIMEOUT=300
  OPUS_TIMEOUT=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.opus.timeout // empty' 2>/dev/null) || true
  [[ -z "${OPUS_TIMEOUT}" ]] && OPUS_TIMEOUT=600

  # Per-tier tool lists
  HAIKU_TOOLS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.haiku.tools // empty' 2>/dev/null) || true
  [[ -z "${HAIKU_TOOLS}" ]] && HAIKU_TOOLS="Edit,Read"
  SONNET_TOOLS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.sonnet.tools // empty' 2>/dev/null) || true
  [[ -z "${SONNET_TOOLS}" ]] && SONNET_TOOLS="Edit,Read"
  OPUS_TOOLS=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.tiers.opus.tools // empty' 2>/dev/null) || true
  [[ -z "${OPUS_TOOLS}" ]] && OPUS_TOOLS="Edit,Read,Write"

  readonly HAIKU_CODE_PATTERN SONNET_CODE_PATTERN OPUS_CODE_PATTERN VOLUME_THRESHOLD
  readonly GLOBAL_MODEL_OVERRIDE MAX_TURNS_OVERRIDE TIMEOUT_OVERRIDE
  readonly HAIKU_MAX_TURNS SONNET_MAX_TURNS OPUS_MAX_TURNS
  readonly HAIKU_TIMEOUT SONNET_TIMEOUT OPUS_TIMEOUT
  readonly HAIKU_TOOLS SONNET_TOOLS OPUS_TOOLS
}

# Check if auto-format phase is enabled (default: true)
is_auto_format_enabled() {
  local enabled
  enabled=$(echo "${CONFIG_JSON}" | jaq -r '.phases.auto_format' 2>/dev/null)
  [[ "${enabled}" != "false" ]]
}

# Check if subprocess delegation is enabled (default: true)
is_subprocess_enabled() {
  local enabled
  enabled=$(echo "${CONFIG_JSON}" | jaq -r '.phases.subprocess_delegation' 2>/dev/null)
  [[ "${enabled}" != "false" ]]
}

# Check if TypeScript is enabled (handles both legacy boolean and nested object)
is_typescript_enabled() {
  local ts_config
  ts_config=$(echo "${CONFIG_JSON}" | jaq -r '.languages.typescript' 2>/dev/null)
  case "${ts_config}" in
    false | null) return 1 ;;
    true) return 0 ;;
    *) # nested object - check .enabled field
      local enabled
      enabled=$(echo "${CONFIG_JSON}" | jaq -r '.languages.typescript.enabled // false' 2>/dev/null)
      [[ "${enabled}" != "false" ]]
      ;;
  esac
}

# Get a nested TS config value with default
get_ts_config() {
  local key="$1"
  local default="$2"
  echo "${CONFIG_JSON}" | jaq -r ".languages.typescript.${key} // \"${default}\"" 2>/dev/null
}

# Detect Biome binary with session caching (D8)
detect_biome() {
  local cache_file="/tmp/.biome_path_${SESSION_PID}"

  # Check session cache first
  if [[ -f "${cache_file}" ]]; then
    local cached
    cached=$(cat "${cache_file}")
    if [[ -n "${cached}" ]]; then
      echo "${cached}"
      return 0
    fi
  fi

  local biome_cmd=""
  local js_runtime
  js_runtime=$(get_ts_config "js_runtime" "auto")

  if [[ "${js_runtime}" != "auto" ]]; then
    # Explicit runtime configured
    case "${js_runtime}" in
      npm) biome_cmd="npx biome" ;;
      pnpm) biome_cmd="pnpm exec biome" ;;
      bun) biome_cmd="bunx biome" ;;
      *) ;;
    esac
  else
    # Auto-detect: project-local -> PATH -> npx -> pnpm -> bunx
    if [[ -x "./node_modules/.bin/biome" ]]; then
      biome_cmd="$(cd . && pwd)/node_modules/.bin/biome"
    elif command -v biome >/dev/null 2>&1; then
      biome_cmd="biome"
    elif command -v npx >/dev/null 2>&1; then
      biome_cmd="npx biome"
    elif command -v pnpm >/dev/null 2>&1; then
      biome_cmd="pnpm exec biome"
    elif command -v bunx >/dev/null 2>&1; then
      biome_cmd="bunx biome"
    fi
  fi

  if [[ -n "${biome_cmd}" ]]; then
    echo "${biome_cmd}" >"${cache_file}"
    echo "${biome_cmd}"
    return 0
  fi

  return 1
}

# Initialize configuration
load_config

# Master kill switch: hook_enabled=false in config.json disables all linting
if [[ "$(echo "${CONFIG_JSON}" | jaq -r '.hook_enabled' 2>/dev/null || true)" == "false" ]]; then
  exit_json
fi
check_config_migration || exit_json
load_model_patterns

# Read JSON input from stdin
input=$(cat)
tool_name=$(jaq -r '.tool_name // empty' <<<"${input}" 2>/dev/null) || tool_name=""
[[ -z "${tool_name}" ]] && tool_name="unknown"

# Track if any issues found
has_issues=false

# Collected violations for delegation (JSON array)
collected_violations="[]"

# File type for delegation
file_type=""

# Note: HOOK_SUBPROCESS_TIMEOUT env var is handled inside load_model_patterns

# Extract file path from tool_input
file_path=$(jaq -r '.tool_input?.file_path? // .tool_input?.notebook_path? // empty' <<<"${input}" 2>/dev/null) || file_path=""

# Skip if no file path or file doesn't exist
[[ -z "${file_path}" ]] && exit_json
[[ ! -f "${file_path}" ]] && exit_json

# ============================================================================
# PATH EXCLUSION FOR SECURITY LINTERS
# ============================================================================
# Matches common exclusion paths for tools like vulture/bandit.
# Used to skip security linters on test files, scripts, etc. where false
# positives are expected (e.g., intentional security patterns in tests).
is_excluded_from_security_linters() {
  local fp="$1"

  # Normalize absolute paths to relative (using CLAUDE_PROJECT_DIR if available)
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && [[ "${fp}" == "${CLAUDE_PROJECT_DIR}"/* ]]; then
    fp="${fp#"${CLAUDE_PROJECT_DIR}"/}"
  fi

  local exclusion
  local exclusions
  exclusions=$(get_security_linter_exclusions || true)
  while IFS= read -r exclusion; do
    [[ -z "${exclusion}" ]] && continue
    if [[ "${fp}" == ${exclusion}* ]]; then
      return 0
    fi
  done <<<"${exclusions}"
  return 1
}

# ============================================================================
# DELEGATION FUNCTIONS
# ============================================================================

# Spawn claude subprocess to fix violations
spawn_fix_subprocess() {
  local fp="$1"
  local violations_json="$2"
  local ftype="$3"

  # Filter violations for docstring-specialized branch (BUG-7 fix)
  # If Python file has real D### docstring codes, narrow to D-only subset.
  # Non-D violations are handled by the rerun loop after docstrings are fixed.
  local prompt_violations_json="${violations_json}"
  if [[ "${ftype}" == "python" ]] && echo "${violations_json}" | jaq -e '[.[] | select(.code | test("^D[0-9]+$"))] | length > 0' >/dev/null 2>&1; then
    prompt_violations_json=$(echo "${violations_json}" | jaq -c '[.[] | select(.code | test("^D[0-9]+$"))]' 2>/dev/null) || prompt_violations_json="${violations_json}"
  fi

  # Compute prompt-side count and codes once (used for logs and model selection)
  local prompt_count prompt_codes
  prompt_count=$(echo "${prompt_violations_json}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
  prompt_codes=$(echo "${prompt_violations_json}" | jaq -r '[.[].code] | sort | unique | join(",")' 2>/dev/null || echo "")
  hook_diag "phase=delegate_plan tool=${tool_name} file=${fp} ftype=${ftype} count=${prompt_count} codes=${prompt_codes}"

  # Model selection based on violation complexity
  local count="${prompt_count}"

  local model=""
  local tier_max_turns=""
  local tier_timeout=""
  local tier_tools=""

  # Global model override skips all tier selection
  if [[ -n "${GLOBAL_MODEL_OVERRIDE}" ]]; then
    model="${GLOBAL_MODEL_OVERRIDE}"
  else
    # Check for opus-level codes
    local has_opus_codes="false"
    if echo "${prompt_violations_json}" | jaq -e '[.[] | select(.code | test("'"${OPUS_CODE_PATTERN}"'"))] | length > 0' >/dev/null 2>&1; then
      has_opus_codes="true"
    fi

    # Check for sonnet-level codes
    local has_sonnet_codes="false"
    if echo "${prompt_violations_json}" | jaq -e '[.[] | select(.code | test("'"${SONNET_CODE_PATTERN}"'"))] | length > 0' >/dev/null 2>&1; then
      has_sonnet_codes="true"
    fi

    # Select model: haiku (default) -> sonnet -> opus (complex or >threshold)
    model="haiku"
    if [[ "${has_sonnet_codes}" == "true" ]]; then
      model="sonnet"
    fi
    if [[ "${has_opus_codes}" == "true" ]] || [[ "${count}" -gt "${VOLUME_THRESHOLD}" ]]; then
      model="opus"
    fi
  fi

  # Warn about violation codes that don't match any tier pattern
  if [[ "${model}" == "haiku" ]] && [[ -z "${GLOBAL_MODEL_OVERRIDE}" ]]; then
    local unmatched_codes
    unmatched_codes=$(echo "${prompt_violations_json}" | jaq -r '.[].code' 2>/dev/null | sort -u) || true
    while IFS= read -r code; do
      [[ -z "${code}" ]] && continue
      local matched="false"
      if echo "${code}" | grep -qE "^(${HAIKU_CODE_PATTERN})$" 2>/dev/null; then matched="true"; fi
      if echo "${code}" | grep -qE "^(${SONNET_CODE_PATTERN})$" 2>/dev/null; then matched="true"; fi
      if echo "${code}" | grep -qE "^(${OPUS_CODE_PATTERN})$" 2>/dev/null; then matched="true"; fi
      if [[ "${matched}" == "false" ]]; then
        echo "[hook:warning] unmatched pattern '${code}', defaulting to haiku" >&2
      fi
    done <<<"${unmatched_codes}"
  fi

  # Resolve per-tier settings
  case "${model}" in
    opus)
      tier_max_turns="${OPUS_MAX_TURNS}"
      tier_timeout="${OPUS_TIMEOUT}"
      tier_tools="${OPUS_TOOLS}"
      ;;
    sonnet)
      tier_max_turns="${SONNET_MAX_TURNS}"
      tier_timeout="${SONNET_TIMEOUT}"
      tier_tools="${SONNET_TOOLS}"
      ;;
    *)
      tier_max_turns="${HAIKU_MAX_TURNS}"
      tier_timeout="${HAIKU_TIMEOUT}"
      tier_tools="${HAIKU_TOOLS}"
      ;;
  esac

  # Apply cross-tier overrides
  [[ -n "${MAX_TURNS_OVERRIDE}" ]] && tier_max_turns="${MAX_TURNS_OVERRIDE}"
  [[ -n "${TIMEOUT_OVERRIDE}" ]] && tier_timeout="${TIMEOUT_OVERRIDE}"

  # Debug output for testing model selection
  if [[ "${HOOK_DEBUG_MODEL:-}" == "1" ]]; then
    echo "[hook:model] ${model} (count=${count}, opus_codes=${has_opus_codes:-n/a}, sonnet_codes=${has_sonnet_codes:-n/a})" >&2
  fi

  # Build prompt for subprocess (file-type specific for better fixes)
  local prompt
  if [[ "${ftype}" == "markdown" ]]; then
    # Markdown-specific prompt with semantic fix strategies
    prompt="You are a markdown fixer. Fix ALL violations in ${fp}.

VIOLATIONS:
${prompt_violations_json}

MARKDOWN FIX STRATEGIES:
- MD013 (line length >80): SHORTEN content, don't wrap. Examples:
  - 'Skip delegation, report violations directly' -> 'Skip delegation, report directly'
  - 'Refactor to early returns, extract Config class' -> 'Refactor to early returns'
  - Remove redundant words: 'in order to' -> 'to', 'that is' -> ''
- MD060 (table style): Add spaces around ALL pipes in separator rows:
  - WRONG: |--------|------|
  - RIGHT: | ------ | ---- |
- Tables: When shortening, preserve meaning. Abbreviate consistently.

RULES:
1. Use targeted Edit operations - fix specific lines, never rewrite entire file
2. For tables: edit the ENTIRE row in one Edit to keep columns consistent
3. The hook pipeline will auto-format and re-run validation after your edits


Be concise. No explanations in the file."
  elif [[ "${ftype}" == "python" ]] && echo "${prompt_violations_json}" | jaq -e '[.[] | select(.code | test("^D[0-9]+$"))] | length > 0' >/dev/null 2>&1; then
    # Python with docstring violations - specialized prompt
    # __init__.py-specific D100 hint (conditional)
    local init_hint=""
    if [[ "$(basename "${fp}")" == "__init__.py" ]]; then
      init_hint=$'\n- For __init__.py: D100 needs module docstring at top of file. Keep minimal (one-line).'
    fi
    prompt="You are a docstring fixer. Fix ALL docstring violations in ${fp}.

VIOLATIONS:
${prompt_violations_json}

DOCSTRING FIX STRATEGIES:
- D401 (imperative mood): Change 'Returns the value' -> 'Return the value', 'Gets data' -> 'Get data'
- D417 (missing Args): Add Args section with parameter descriptions from function signature
- D205 (blank line): Add blank line after one-line summary
- D400/D415 (trailing punctuation): Add period at end of first line
- D301 (backslash): Use raw docstring r\"\"\" for regex patterns
- D100/D104 (module/package): Add module-level docstring at file start${init_hint}
- D107 (__init__): Add docstring explaining initialization parameters

RULES:
1. Use targeted Edit operations - fix specific docstrings, never rewrite entire file
2. Preserve existing docstring content, only fix the specific violation
3. Follow Google docstring style (Args:, Returns:, Raises:)
4. The hook pipeline will auto-format and re-run validation after your edits


Be concise. Fix docstrings only, do not refactor code."
  else
    # Generic prompt for other file types
    prompt="You are a code quality fixer. Fix ALL violations listed below in ${fp}.

VIOLATIONS:
${prompt_violations_json}

RULES:
1. Use targeted Edit operations only - never rewrite the entire file
2. Fix each violation at its reported line/column
3. The hook pipeline will auto-format and re-run validation after your edits

4. If a violation cannot be fixed, explain why

Do not add comments explaining fixes. Do not refactor beyond what's needed."
  fi

  # Find claude binary
  local claude_cmd=""
  if command -v claude >/dev/null 2>&1; then
    claude_cmd="claude"
  else
    # Search in common locations
    local search_dirs="${HOME}/.local/bin ${HOME}/.npm-global/bin /usr/local/bin"
    for dir in ${search_dirs}; do
      if [[ -x "${dir}/claude" ]]; then
        claude_cmd="${dir}/claude"
        break
      fi
    done
  fi

  if [[ -z "${claude_cmd}" ]]; then
    echo "[hook:error] claude binary not found, cannot delegate" >&2
    return 0
  fi

  # Resolve settings file: config override > project-local default
  local settings_file
  settings_file=$(echo "${CONFIG_JSON}" | jaq -r '.subprocess.settings_file // empty' 2>/dev/null) || true
  # Expand leading tilde to $HOME
  settings_file="${settings_file/#\~/${HOME}}"
  if [[ -z "${settings_file}" ]]; then
    settings_file="${CLAUDE_PROJECT_DIR:-.}/.claude/subprocess-settings.json"
  fi

  # Auto-create if missing (atomic mktemp+mv for concurrent invocations)
  if [[ ! -f "${settings_file}" ]]; then
    local settings_dir
    settings_dir=$(dirname "${settings_file}")
    mkdir -p "${settings_dir}"
    local tmpfile
    tmpfile=$(mktemp "${settings_file}.XXXXXX") || {
      echo "[hook:error] failed to create temp file for settings" >&2
      return 1
    }
    cat >"${tmpfile}" <<'SETTINGS_EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true
}
SETTINGS_EOF
    if mv "${tmpfile}" "${settings_file}" 2>/dev/null; then
      echo "[hook:warning] created missing ${settings_file}" >&2
    else
      rm -f "${tmpfile}" # Lost race - another process created it first
    fi
  fi
  # Use timeout if available (requires GNU coreutils on macOS: brew install coreutils)
  local effective_timeout="${tier_timeout}"
  local timeout_cmd=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout ${effective_timeout}"
  fi

  # Tool universe for --disallowedTools derivation (pinned to cc_tested_version)
  # Update when upgrading cc_tested_version in config.json
  local tool_universe="Edit,Read,Write,Bash,Glob,Grep,WebFetch,WebSearch,NotebookEdit,Task,AskUserQuestion,EnterPlanMode,ExitPlanMode"
  local allowed_tools="${tier_tools}"

  # Derive disallowed tools: universe minus allowed
  local disallowed_tools=""
  local IFS_BAK="${IFS}"
  IFS=','
  for tool in ${tool_universe}; do
    local is_allowed="false"
    for at in ${allowed_tools}; do
      if [[ "${tool}" == "${at}" ]]; then
        is_allowed="true"
        break
      fi
    done
    if [[ "${is_allowed}" == "false" ]]; then
      if [[ -n "${disallowed_tools}" ]]; then
        disallowed_tools="${disallowed_tools},${tool}"
      else
        disallowed_tools="${tool}"
      fi
    fi
  done
  IFS="${IFS_BAK}"

  if [[ -z "${disallowed_tools}" ]]; then
    echo "[hook:warning] all tools allowed for tier (disallowedTools is empty)" >&2
  fi
  # Log subprocess parameters for diagnostics
  echo "[hook:subprocess] model=${model} tools=${allowed_tools} max_turns=${tier_max_turns} timeout=${effective_timeout}" >&2

  # Capture file state before subprocess for modification detection
  local file_hash_before=""
  if [[ -f "${fp}" ]]; then
    file_hash_before=$(cksum "${fp}" 2>/dev/null || true)
  fi

  # Spawn subprocess — stderr flows through for observability (visible via
  # claude --debug), stdout discarded. Safety invariant: --dangerously-skip-permissions
  # is never passed without --disallowedTools also being present.
  local disallowed_flag=()
  if [[ -n "${disallowed_tools}" ]]; then
    disallowed_flag=(--disallowedTools "${disallowed_tools}")
  fi
  local delegate_started=${SECONDS}
  hook_diag "phase=delegate_start tool=${tool_name} file=${fp} ftype=${ftype} model=${model} max_turns=${tier_max_turns} timeout=${effective_timeout} allowed_tools=${allowed_tools} count=${prompt_count} codes=${prompt_codes}"
  subprocess_exit=0
  ${timeout_cmd} env -u CLAUDECODE "${claude_cmd}" -p "${prompt}" \
    --dangerously-skip-permissions \
    --setting-sources "" \
    --settings "${settings_file}" \
    "${disallowed_flag[@]}" \
    --max-turns "${tier_max_turns}" \
    --model "${model}" \
    "${fp}" >/dev/null || subprocess_exit=$?

  # Detect file modification
  local file_hash_after=""
  if [[ -f "${fp}" ]]; then
    file_hash_after=$(cksum "${fp}" 2>/dev/null || true)
  fi
  if [[ "${file_hash_before}" != "${file_hash_after}" ]]; then
    echo "[hook:subprocess] file modified" >&2
  else
    echo "[hook:subprocess] file unchanged" >&2
  fi
  local delegate_duration=$((SECONDS - delegate_started))
  local _changed="no"
  [[ "${file_hash_before}" != "${file_hash_after}" ]] && _changed="yes"
  hook_diag "phase=delegate_end tool=${tool_name} file=${fp} ftype=${ftype} model=${model} exit=${subprocess_exit} changed=${_changed} duration_s=${delegate_duration}"

  # Report subprocess failures (but don't fail the hook)
  if [[ "${subprocess_exit}" -ne 0 ]]; then
    if [[ "${subprocess_exit}" -eq 124 ]]; then
      echo "[hook:warning] subprocess timed out (exit ${subprocess_exit})" >&2
    else
      echo "[hook:warning] subprocess failed (exit ${subprocess_exit})" >&2
    fi
  fi
}

# Re-run Phase 1 auto-fix for a file type
rerun_phase1() {
  local fp="$1"
  local ftype="$2"

  case "${ftype}" in
    python)
      command -v ruff >/dev/null 2>&1 && {
        ruff format --quiet "${fp}" >/dev/null 2>&1 || true
        ruff check --fix --quiet "${fp}" >/dev/null 2>&1 || true
      }
      ;;
    shell)
      command -v shfmt >/dev/null 2>&1 && {
        shfmt -w -i 2 -ci -bn "${fp}" 2>/dev/null || true
      }
      ;;
    toml)
      command -v taplo >/dev/null 2>&1 && {
        RUST_LOG=error taplo fmt "${fp}" 2>/dev/null || true
      }
      ;;
    markdown)
      command -v markdownlint-cli2 >/dev/null 2>&1 && {
        markdownlint-cli2 --no-globs --fix "${fp}" 2>/dev/null || true
      }
      ;;
    json)
      # Re-validate and format if valid
      # Use Biome if TS enabled and available (D6), fallback to jaq pretty-print
      if jaq empty "${fp}" 2>/dev/null; then
        local json_done=false
        if is_typescript_enabled; then
          local _biome_cmd
          _biome_cmd=$(detect_biome 2>/dev/null) || _biome_cmd=""
          if [[ -n "${_biome_cmd}" ]]; then
            ${_biome_cmd} format --write "${fp}" >/dev/null 2>&1 && json_done=true
          fi
        fi
        if [[ "${json_done}" == "false" ]]; then
          local tmp_file
          tmp_file=$(mktemp) || return
          if jaq '.' "${fp}" >"${tmp_file}" 2>/dev/null; then
            if ! cmp -s "${fp}" "${tmp_file}"; then
              mv "${tmp_file}" "${fp}"
            else
              rm -f "${tmp_file}"
            fi
          else
            rm -f "${tmp_file}"
          fi
        fi
      fi
      ;;
    typescript)
      local _biome_cmd
      _biome_cmd=$(detect_biome 2>/dev/null) || _biome_cmd=""
      if [[ -n "${_biome_cmd}" ]]; then
        local _unsafe_flag=""
        local _unsafe
        _unsafe=$(get_ts_config "biome_unsafe_autofix" "false")
        [[ "${_unsafe}" == "true" ]] && _unsafe_flag="--unsafe"
        local rel_path
        rel_path=$(_biome_relpath "${fp}")
        if [[ -n "${_unsafe_flag}" ]]; then
          (cd "${CLAUDE_PROJECT_DIR:-.}" && ${_biome_cmd} check --write "${_unsafe_flag}" "${rel_path}") >/dev/null 2>&1 || true
        else
          (cd "${CLAUDE_PROJECT_DIR:-.}" && ${_biome_cmd} check --write "${rel_path}") >/dev/null 2>&1 || true
        fi
      fi
      ;;
    *) ;; # No Phase 1 for yaml, dockerfile
  esac
}

# Re-run Phase 2 and return violation count
rerun_phase2() {
  local fp="$1"
  local ftype="$2"
  local count=0
  RERUN_PHASE2_RAW=""
  RERUN_PHASE2_COUNT=0
  RERUN_PHASE2_CODES=""

  case "${ftype}" in
    python)
      local all_codes=""

      # Ruff violations
      local v
      v=$(ruff check --preview --output-format=json "${fp}" 2>/dev/null) || true
      count=$(echo "${v}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
      RERUN_PHASE2_RAW="${v}"
      local ruff_codes
      # shellcheck disable=SC2016
      ruff_codes=$(echo "${v}" | jaq -r '[.[].code // empty] | unique | join(", ")' 2>/dev/null) || ruff_codes=""
      [[ -n "${ruff_codes}" ]] && all_codes="${ruff_codes}"

      # ty violations (uv run for project venv)
      if command -v uv >/dev/null 2>&1; then
        local ty_out
        ty_out=$(uv run ty check --output-format gitlab "${fp}" 2>/dev/null) || true
        local ty_count
        ty_count=$(echo "${ty_out}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
        count=$((count + ty_count))
        local ty_codes=""
        if [[ "${ty_count}" -gt 0 ]]; then
          # shellcheck disable=SC2016
          ty_codes=$(echo "${ty_out}" | jaq -r '[.[].check_name // empty] | unique | join(", ")' 2>/dev/null) || ty_codes=""
          [[ -z "${ty_codes}" ]] && ty_codes=$(echo "${ty_out}" | grep -oE '\[[a-z-]+\]' | tr -d '[]' | sort -u | paste -sd ', ' -) || true
        fi
        [[ -n "${ty_codes}" ]] && all_codes="${all_codes:+${all_codes}, }${ty_codes}"
      fi

      # flake8-pydantic violations (uv run for project venv)
      if command -v uv >/dev/null 2>&1; then
        local pyd_out
        pyd_out=$(uv run flake8 --select=PYD "${fp}" 2>/dev/null || true)
        if [[ -n "${pyd_out}" ]]; then
          local pyd_count
          pyd_count=$(echo "${pyd_out}" | wc -l | tr -d ' ')
          count=$((count + pyd_count))
          local pyd_codes=""
          pyd_codes=$(echo "${pyd_out}" | grep -oE 'PYD[0-9]+' | sort -u | paste -sd ', ' -) || pyd_codes=""
          [[ -n "${pyd_codes}" ]] && all_codes="${all_codes:+${all_codes}, }${pyd_codes}"
        fi
      fi

      # vulture violations
      if command -v uv >/dev/null 2>&1; then
        local vulture_out
        vulture_out=$(uv run vulture "${fp}" --min-confidence 80 2>/dev/null || true)
        if [[ -n "${vulture_out}" ]]; then
          local vulture_count
          vulture_count=$(echo "${vulture_out}" | wc -l | tr -d ' ')
          count=$((count + vulture_count))
          [[ -n "${vulture_out}" ]] && all_codes="${all_codes:+${all_codes}, }unused-code"
        fi
      fi

      # bandit violations
      if command -v uv >/dev/null 2>&1; then
        local bandit_out
        bandit_out=$(uv run bandit -f json -q "${fp}" 2>/dev/null) || true
        local bandit_count
        bandit_count=$(echo "${bandit_out}" | jaq '.results | length // 0' 2>/dev/null | head -n1 || echo "0")
        count=$((count + bandit_count))
        local bandit_codes=""
        if [[ "${bandit_count}" -gt 0 ]]; then
          # shellcheck disable=SC2016
          bandit_codes=$(echo "${bandit_out}" | jaq -r '[.results[].test_id // empty] | unique | join(", ")' 2>/dev/null) || bandit_codes=""
        fi
        [[ -n "${bandit_codes}" ]] && all_codes="${all_codes:+${all_codes}, }${bandit_codes}"
      fi

      # flake8-async violations
      if command -v uv >/dev/null 2>&1; then
        local async_out
        async_out=$(uv run flake8 --select=ASYNC "${fp}" 2>/dev/null || true)
        if [[ -n "${async_out}" ]]; then
          local async_count
          async_count=$(echo "${async_out}" | wc -l | tr -d ' ')
          count=$((count + async_count))
          local async_codes=""
          async_codes=$(echo "${async_out}" | grep -oE 'ASYNC[0-9]+' | sort -u | paste -sd ', ' -) || async_codes=""
          [[ -n "${async_codes}" ]] && all_codes="${all_codes:+${all_codes}, }${async_codes}"
        fi
      fi

      RERUN_PHASE2_CODES="${all_codes}"
      ;;
    shell)
      if command -v shellcheck >/dev/null 2>&1; then
        local v
        v=$(shellcheck -f json "${fp}" 2>/dev/null) || true
        count=$(echo "${v}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
        RERUN_PHASE2_RAW="${v}"
      fi
      ;;
    yaml)
      if command -v yamllint >/dev/null 2>&1; then
        local v
        v=$(yamllint -f parsable "${fp}" 2>/dev/null || true)
        [[ -n "${v}" ]] && count=$(echo "${v}" | wc -l | tr -d ' ')
        RERUN_PHASE2_RAW="${v}"
      fi
      ;;
    json)
      # Check syntax only
      if ! jaq empty "${fp}" 2>/dev/null; then
        count=1
      fi
      ;;
    toml)
      if command -v taplo >/dev/null 2>&1; then
        local v
        v=$(RUST_LOG=error taplo check "${fp}" 2>&1) || true
        [[ -n "${v}" ]] && count=1
        RERUN_PHASE2_RAW="${v}"
      fi
      ;;
    markdown)
      if command -v markdownlint-cli2 >/dev/null 2>&1; then
        local v
        v=$(markdownlint-cli2 --no-globs "${fp}" 2>&1 || true)
        if [[ -n "${v}" ]] && ! echo "${v}" | grep -q "Summary: 0 error"; then
          count=$(echo "${v}" | grep -c ":" || echo "1")
        fi
        RERUN_PHASE2_RAW="${v}"
      fi
      ;;
    dockerfile)
      if command -v hadolint >/dev/null 2>&1; then
        local v
        v=$(hadolint --no-color -f json "${fp}" 2>/dev/null) || true
        count=$(echo "${v}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
        RERUN_PHASE2_RAW="${v}"
      fi
      ;;
    typescript)
      local _biome_cmd
      _biome_cmd=$(detect_biome 2>/dev/null) || _biome_cmd=""
      if [[ -n "${_biome_cmd}" ]]; then
        local biome_out
        local rel_path
        rel_path=$(_biome_relpath "${fp}")
        biome_out=$( (cd "${CLAUDE_PROJECT_DIR:-.}" && ${_biome_cmd} lint --reporter=json "${rel_path}") 2>/dev/null || true)
        if [[ -n "${biome_out}" ]]; then
          count=$(echo "${biome_out}" | jaq '[(.diagnostics // [])[] |
            select(.severity == "error" or .severity == "warning")] | length' 2>/dev/null | head -n1 || echo "0")
        fi
        RERUN_PHASE2_RAW="${biome_out}"
      fi
      ;;
    *) ;; # Unknown file type
  esac

  RERUN_PHASE2_COUNT="${count}"
}

# Extract violation codes from RERUN_PHASE2_RAW for directive messages.
# Sets global VIOLATION_CODES (comma-separated string).
extract_violation_codes() {
  local ftype="$1"
  VIOLATION_CODES=""

  if [[ -z "${RERUN_PHASE2_RAW:-}" ]] && [[ -z "${RERUN_PHASE2_CODES:-}" ]]; then
    return
  fi

  case "${ftype}" in
    python)
      if [[ -n "${RERUN_PHASE2_CODES:-}" ]]; then
        VIOLATION_CODES="${RERUN_PHASE2_CODES}"
      else
        # shellcheck disable=SC2016 # jaq uses $var, not shell
        VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | jaq -r '[.[].code] | unique | join(", ")' 2>/dev/null) || VIOLATION_CODES=""
      fi
      ;;
    shell)
      # shellcheck disable=SC2016
      VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | jaq -r '[.[] | "SC" + (.code | tostring)] | unique | join(", ")' 2>/dev/null) || VIOLATION_CODES=""
      ;;
    markdown)
      VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | grep -oE 'MD[0-9]+(/[a-z-]+)?' | sort -u | paste -sd ', ' -) || VIOLATION_CODES=""
      ;;
    yaml)
      VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | grep -oE '\([^)]+\)' | tr -d '()' | sort -u | paste -sd ', ' -) || VIOLATION_CODES=""
      ;;
    dockerfile)
      # shellcheck disable=SC2016
      VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | jaq -r '[.[].code] | unique | join(", ")' 2>/dev/null) || VIOLATION_CODES=""
      ;;
    toml)
      VIOLATION_CODES="TOML_SYNTAX"
      ;;
    typescript)
      # shellcheck disable=SC2016
      VIOLATION_CODES=$(echo "${RERUN_PHASE2_RAW}" | jaq -r '[(.diagnostics // [])[] | .category // empty] | unique | join(", ")' 2>/dev/null) || VIOLATION_CODES=""
      ;;
    *) ;;
  esac
}

# ============================================================================
# TYPESCRIPT HANDLER
# ============================================================================

# Semgrep session-scoped helper (D2, D11)
_handle_semgrep_session() {
  local fp="$1"
  local semgrep_enabled
  semgrep_enabled=$(get_ts_config "semgrep" "true")
  [[ "${semgrep_enabled}" == "false" ]] && return

  local session_file="/tmp/.semgrep_session_${SESSION_PID}"
  echo "${fp}" >>"${session_file}" 2>/dev/null || true

  if [[ -f "${session_file}" ]]; then
    local file_count
    file_count=$(wc -l <"${session_file}" 2>/dev/null | tr -d ' ')
    if [[ "${file_count}" -ge 3 ]] && [[ ! -f "${session_file}.done" ]]; then
      touch "${session_file}.done"
      if command -v semgrep >/dev/null 2>&1 && [[ -f "${CLAUDE_PROJECT_DIR:-.}/.semgrep.yml" ]]; then
        local semgrep_files
        semgrep_files=$(sort -u "${session_file}" | tr '\n' ' ') || semgrep_files=""
        local semgrep_result
        # shellcheck disable=SC2086  # Intentional word splitting for file list
        semgrep_result=$(semgrep --json --config "${CLAUDE_PROJECT_DIR:-.}/.semgrep.yml" \
          ${semgrep_files} 2>/dev/null || true)
        if [[ -n "${semgrep_result}" ]]; then
          local finding_count
          finding_count=$(echo "${semgrep_result}" | jaq '.results | length' 2>/dev/null | head -n1 || echo "0")
          if [[ "${finding_count}" -gt 0 ]]; then
            {
              echo ""
              echo "[hook:advisory] Semgrep: ${finding_count} security finding(s)"
              echo "Run 'semgrep --config .semgrep.yml' for details."
              echo ""
            } >&2
          fi
        fi
      fi
    fi
  fi
}

# jscpd session-scoped helper for TypeScript (D17)
_handle_jscpd_ts_session() {
  local fp="$1"
  local session_file="/tmp/.jscpd_ts_session_${SESSION_PID}"
  echo "${fp}" >>"${session_file}" 2>/dev/null || true

  if [[ -f "${session_file}" ]]; then
    local file_count
    file_count=$(wc -l <"${session_file}" 2>/dev/null | tr -d ' ')
    if [[ "${file_count}" -ge 3 ]] && [[ ! -f "${session_file}.done" ]]; then
      touch "${session_file}.done"
      if command -v npx >/dev/null 2>&1; then
        local jscpd_result
        jscpd_result=$(npx jscpd --config .jscpd.json --reporters json \
          --silent 2>/dev/null || true)
        if [[ -n "${jscpd_result}" ]]; then
          local clone_count
          clone_count=$(echo "${jscpd_result}" \
            | jaq -r 'if .statistics then .statistics.total.clones else if .statistic then .statistic.total.clones else 0 end end' 2>/dev/null || echo "0")
          if [[ "${clone_count}" -gt 0 ]]; then
            {
              echo ""
              echo "[hook:advisory] Duplicate code detected (TS/JS)"
              echo "Clone pairs found: ${clone_count}"
              echo "Run 'npx jscpd --config .jscpd.json' for details."
              echo ""
            } >&2
          fi
        fi
      fi
    fi
  fi
}

# Nursery mismatch validation (D9)
_validate_nursery_config() {
  local biome_cmd="$1"
  local biome_json="${CLAUDE_PROJECT_DIR:-.}/biome.json"
  [[ ! -f "${biome_json}" ]] && return

  local config_nursery
  config_nursery=$(get_ts_config "biome_nursery" "warn")
  local biome_nursery
  biome_nursery=$(jaq -r '.linter.rules.nursery // "off"' "${biome_json}" 2>/dev/null || echo "")

  # Object-valued nursery is fully controlled by biome.json — string comparison not applicable
  [[ "${biome_nursery}" == "{"* || "${biome_nursery}" == "["* ]] && return
  # Normalize: biome.json uses severity strings, config.json uses warn/error/off
  if [[ -n "${biome_nursery}" ]] && [[ "${biome_nursery}" != "null" ]] \
    && [[ "${config_nursery}" != "${biome_nursery}" ]]; then
    echo "[hook:warning] config.json biome_nursery='${config_nursery}' but biome.json nursery='${biome_nursery}' — behavior follows biome.json" >&2
  fi
}

# Biome project-domain rules (nursery) require relative paths (biome 2.3.x).
# Convert absolute path to relative for biome invocations.
_biome_relpath() {
  local abs="$1"
  local base="${CLAUDE_PROJECT_DIR:-.}"
  if [[ "${abs}" == "${base}/"* ]]; then
    echo "${abs#"${base}/"}"
  else
    echo "[hook:warning] file outside project root, biome project rules may not apply" >&2
    echo "${abs}"
  fi
}

# Main TypeScript handler (D1, D4, D7, D9-D11)
handle_typescript() {
  local fp="$1"
  local ext="${fp##*.}"
  local _merged

  # Detect Biome
  local biome_cmd
  biome_cmd=$(detect_biome 2>/dev/null) || biome_cmd=""

  # SFC handling (D4): .vue/.svelte/.astro -> Semgrep only, skip Biome
  case "${ext}" in
    vue | svelte | astro)
      local sfc_warned="/tmp/.sfc_warned_${ext}_${SESSION_PID}"
      if [[ ! -f "${sfc_warned}" ]]; then
        touch "${sfc_warned}"
        if ! command -v semgrep >/dev/null 2>&1; then
          echo "[hook:warning] No linter available for .${ext} files. Install semgrep for security scanning: brew install semgrep" >&2
        fi
      fi
      # Run Semgrep session tracking only for SFC files
      _handle_semgrep_session "${fp}"
      return
      ;;
    *) ;;
  esac

  # Biome required for non-SFC TS/JS/CSS files
  if [[ -z "${biome_cmd}" ]]; then
    echo "[hook:warning] biome not found. Install: npm i -D @biomejs/biome" >&2
    return
  fi

  # One-time nursery config validation per session
  local nursery_checked="/tmp/.nursery_checked_${SESSION_PID}"
  if [[ ! -f "${nursery_checked}" ]]; then
    touch "${nursery_checked}"
    _validate_nursery_config "${biome_cmd}"
  fi

  # Phase 1: Auto-format (silent) (D1, D10)
  if is_auto_format_enabled; then
    local unsafe_config
    unsafe_config=$(get_ts_config "biome_unsafe_autofix" "false")
    local rel_path
    rel_path=$(_biome_relpath "${fp}")
    if [[ "${unsafe_config}" == "true" ]]; then
      (cd "${CLAUDE_PROJECT_DIR:-.}" && ${biome_cmd} check --write --unsafe "${rel_path}") >/dev/null 2>&1 || true
    else
      (cd "${CLAUDE_PROJECT_DIR:-.}" && ${biome_cmd} check --write "${rel_path}") >/dev/null 2>&1 || true
    fi
  fi

  # Phase 2a: Biome lint (blocking) (D1, D3)
  # D3: When oxlint enabled, skip 3 overlapping nursery rules
  local biome_lint_args=("lint" "--reporter=json")
  local oxlint_enabled
  oxlint_enabled=$(get_ts_config "oxlint_tsgolint" "false")
  if [[ "${oxlint_enabled}" == "true" ]]; then
    biome_lint_args+=("--skip=nursery/noFloatingPromises")
    biome_lint_args+=("--skip=nursery/noMisusedPromises")
    biome_lint_args+=("--skip=nursery/useAwaitThenable")
  fi
  local biome_output
  local rel_path_lint
  rel_path_lint=$(_biome_relpath "${fp}")
  biome_output=$( (cd "${CLAUDE_PROJECT_DIR:-.}" && ${biome_cmd} "${biome_lint_args[@]}" "${rel_path_lint}") 2>/dev/null || true)

  if [[ -n "${biome_output}" ]]; then
    local diag_count
    diag_count=$(echo "${biome_output}" | jaq '.diagnostics | length' 2>/dev/null | head -n1 || echo "0")

    if [[ "${diag_count}" -gt 0 ]]; then
      # Convert Biome diagnostics to standard format
      # Biome uses byte offsets in span; convert to line/column via sourceCode
      local biome_violations
      biome_violations=$(echo "${biome_output}" | jaq '[(.diagnostics // [])[] |
        select(.severity == "error" or .severity == "warning") |
        select(.location.span != null) |
        {
          line: ((.location.sourceCode[0:.location.span[0]] // "") | split("\n") | length),
          column: (((.location.sourceCode[0:.location.span[0]] // "") | split("\n") | last | length) + 1),
          code: .category,
          message: .description,
          linter: "biome"
        }]' 2>/dev/null) || biome_violations="[]"

      if [[ "${biome_violations}" != "[]" ]] && [[ -n "${biome_violations}" ]]; then
        _merged=$(echo "${collected_violations}" "${biome_violations}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi

      # Phase 2b: Nursery advisory count (D9)
      local nursery_mode
      nursery_mode=$(get_ts_config "biome_nursery" "warn")
      if [[ "${nursery_mode}" == "warn" ]]; then
        local nursery_count
        nursery_count=$(echo "${biome_output}" | jaq '[(.diagnostics // [])[] |
          select(.category | startswith("lint/nursery/"))] | length' 2>/dev/null | head -n1 || echo "0")
        if [[ "${nursery_count}" -gt 0 ]]; then
          echo "[hook:advisory] Biome nursery: ${nursery_count} diagnostic(s)" >&2
        fi
      fi
    fi
  fi

  # Phase 2c: Semgrep session-scoped (D2, D11) — CSS excluded per ADR D4
  [[ "${ext}" != "css" ]] && _handle_semgrep_session "${fp}"

  # Phase 2d: jscpd session-scoped (D17)
  _handle_jscpd_ts_session "${fp}"
}

# Determine file type for delegation
# NOTE: .github/workflows/*.yml files are handled as generic YAML (yamllint only).
# Full GitHub Actions validation (actionlint, check-jsonschema) runs at commit-time
# via pre-commit, not here. Rationale: workflow files are rarely edited during
# Claude sessions; yamllint covers syntax; specialized validation at commit-time.
case "${file_path}" in
  *.py) file_type="python" ;;
  *.sh | *.bash) file_type="shell" ;;
  *.yml | *.yaml) file_type="yaml" ;;
  *.json) file_type="json" ;;
  *.toml) file_type="toml" ;;
  *.md | *.mdx) file_type="markdown" ;;
  *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.mts | *.cts | *.css) file_type="typescript" ;;
  *.vue | *.svelte | *.astro) file_type="typescript" ;;
  Dockerfile | Dockerfile.* | */Dockerfile | */Dockerfile.* | *.dockerfile | *.Dockerfile) file_type="dockerfile" ;;
  *.ipynb) exit_json ;; # Notebook — no cell-level linting
  *) exit_json ;;       # Unsupported
esac

# Determine file type and run appropriate linter
case "${file_path}" in
  *.py)
    is_language_enabled "python" || exit_json

    # Python: Phase 1 - Auto-format and auto-fix (silent)
    if is_auto_format_enabled && command -v ruff >/dev/null 2>&1; then
      # Format code (spacing, quotes, line length) - suppress all output
      ruff format --quiet "${file_path}" >/dev/null 2>&1 || true
      # Auto-fix linting issues (unused imports, sorting, blank lines) - suppress all output
      ruff check --fix --quiet "${file_path}" >/dev/null 2>&1 || true
    fi

    # Python: Phase 2 - Collect unfixable issues per pyproject.toml config
    # Note: No --select override - pyproject.toml is single source of truth
    ruff_violations=$(ruff check --preview --output-format=json "${file_path}" 2>/dev/null || true)
    if [[ -n "${ruff_violations}" ]] && [[ "${ruff_violations}" != "[]" ]]; then
      # Convert raw ruff JSON to unified {line,column,code,message,linter} schema
      ruff_converted=$(echo "${ruff_violations}" | jaq '[.[] | {
        line: .location.row,
        column: .location.column,
        code: .code,
        message: .message,
        linter: "ruff"
      }]' 2>/dev/null) || ruff_converted="[]"
      if [[ -n "${ruff_converted}" ]] && [[ "${ruff_converted}" != "[]" ]]; then
        _merged=$(echo "${collected_violations}" "${ruff_converted}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi

    # Python: Phase 2b - Type checking with ty (complementary to ruff)
    # NOTE: Line numbers may differ from source due to ruff format running
    # first. This is expected - the location still helps identify the issue.
    # Uses uv run to leverage project's venv (thin wrapper principle)
    if command -v uv >/dev/null 2>&1; then
      ty_output=$(uv run ty check --output-format gitlab "${file_path}" \
        2>/dev/null || true)
      if [[ -n "${ty_output}" ]] && [[ "${ty_output}" != "[]" ]]; then
        # Convert ty gitlab format to standard format and merge
        ty_converted=$(echo "${ty_output}" | jaq '[.[] | {
          line: .location.positions.begin.line,
          column: .location.positions.begin.column,
          code: .check_name,
          message: .description,
          linter: "ty"
        }]' 2>/dev/null) || ty_converted="[]"
        _merged=$(echo "${collected_violations}" "${ty_converted}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi

    # Python: Phase 2c - Duplicate detection (advisory, session-scoped)
    # Only runs once per session after 3+ Python files modified
    jscpd_session="/tmp/.jscpd_session_${SESSION_PID}"
    echo "${file_path}" >>"${jscpd_session}" 2>/dev/null || true

    if [[ -f "${jscpd_session}" ]]; then
      jscpd_count=$(wc -l <"${jscpd_session}" 2>/dev/null | tr -d ' ')
      if [[ "${jscpd_count}" -ge 3 ]] && [[ ! -f "${jscpd_session}.done" ]]; then
        touch "${jscpd_session}.done"
        if command -v npx >/dev/null 2>&1; then
          jscpd_result=$(npx jscpd --config .jscpd.json --reporters json \
            --silent 2>/dev/null || true)
          if [[ -n "${jscpd_result}" ]]; then
            # jscpd 4.0.7+ uses .statistics; older versions use .statistic (fallback chain)
            clone_count=$(echo "${jscpd_result}" \
              | jaq -r 'if .statistics then .statistics.total.clones else if .statistic then .statistic.total.clones else 0 end end' 2>/dev/null || echo "0")
            if [[ "${clone_count}" -gt 0 ]]; then
              {
                echo ""
                echo "[hook:advisory] Duplicate code detected"
                echo "Clone pairs found: ${clone_count}"
                echo ""
                echo "Run 'npx jscpd --config .jscpd.json' for details."
                echo ""
              } >&2
              # Advisory only - does NOT set has_issues=true
            fi
          fi
        fi
      fi
    fi

    # Python: Phase 2d - Pydantic model linting with flake8-pydantic
    # Note: Uses .flake8 config for per-file-ignores
    # Uses uv run to leverage project's venv (thin wrapper principle)
    if command -v uv >/dev/null 2>&1; then
      pydantic_output=$(uv run flake8 --select=PYD "${file_path}" 2>/dev/null || true)
      if [[ -n "${pydantic_output}" ]]; then
        # Convert flake8 output to JSON format (file:line:col: CODE message)
        # shellcheck disable=SC2016
        pyd_json=$(echo "${pydantic_output}" | while IFS= read -r line; do
          line_num=$(echo "${line}" | sed -E 's/^[^:]*:([0-9]+):[0-9]+: .*/\1/')
          col_num=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:([0-9]+): .*/\1/')
          code=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:[0-9]+: ([A-Z0-9]+) .*/\1/')
          msg=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:[0-9]+: [A-Z0-9]+ (.*)/\1/')
          jaq -n --arg l "${line_num}" --arg c "${col_num}" --arg cd "${code}" --arg m "${msg}" \
            '{line:($l|tonumber),column:($c|tonumber),code:$cd,message:$m,linter:"flake8-pydantic"}'
        done | jaq -s '.') || pyd_json="[]"
        if [[ -n "${pyd_json}" ]]; then
          _merged=$(echo "${collected_violations}" "${pyd_json}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi

    # Python: Phase 2e - Dead code detection with vulture
    # Detects unused functions, variables, classes. Config in pyproject.toml [tool.vulture].
    # Skip excluded paths (tests, scripts, etc.) to avoid false positives
    _excluded_vulture=false
    # shellcheck disable=SC2310  # Intentionally capturing return value, not propagating errors
    is_excluded_from_security_linters "${file_path}" && _vulture_rc=0 || _vulture_rc=$?
    if [[ ${_vulture_rc} -eq 0 ]]; then _excluded_vulture=true; fi
    if ! "${_excluded_vulture}" && command -v uv >/dev/null 2>&1; then
      vulture_output=$(uv run vulture "${file_path}" --min-confidence 80 2>/dev/null || true)
      if [[ -n "${vulture_output}" ]]; then
        # Convert vulture output to JSON (file:line: message pattern)
        # shellcheck disable=SC2016
        vulture_json=$(echo "${vulture_output}" | while IFS= read -r line; do
          line_num=$(echo "${line}" | sed -E 's/^[^:]*:([0-9]+): .*/\1/')
          msg=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+: (.*)/\1/')
          jaq -n --arg l "${line_num}" --arg m "${msg}" \
            '{line:($l|tonumber),column:1,code:"VULTURE",message:$m,linter:"vulture"}'
        done | jaq -s '.') || vulture_json="[]"
        if [[ -n "${vulture_json}" ]] && [[ "${vulture_json}" != "[]" ]]; then
          _merged=$(echo "${collected_violations}" "${vulture_json}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi

    # Python: Phase 2f - Security scanning with bandit
    # Detects common security issues (hardcoded passwords, SQL injection, etc.)
    # Skip excluded paths (tests, scripts, etc.) to avoid false positives
    _excluded_bandit=false
    # shellcheck disable=SC2310  # Intentionally capturing return value, not propagating errors
    is_excluded_from_security_linters "${file_path}" && _bandit_rc=0 || _bandit_rc=$?
    if [[ ${_bandit_rc} -eq 0 ]]; then _excluded_bandit=true; fi
    if ! "${_excluded_bandit}" && command -v uv >/dev/null 2>&1; then
      bandit_output=$(uv run bandit -f json -q "${file_path}" 2>/dev/null) || true
      bandit_results=$(echo "${bandit_output}" | jaq '.results // []' 2>/dev/null) || bandit_results="[]"
      if [[ "${bandit_results}" != "[]" ]] && [[ "${bandit_results}" != "null" ]]; then
        # Convert bandit JSON to standard format
        bandit_converted=$(echo "${bandit_results}" | jaq '[.[] | {
          line: .line_number,
          column: (.col_offset // 1),
          code: .test_id,
          message: .issue_text,
          linter: "bandit"
        }]' 2>/dev/null) || bandit_converted="[]"
        if [[ -n "${bandit_converted}" ]] && [[ "${bandit_converted}" != "[]" ]]; then
          _merged=$(echo "${collected_violations}" "${bandit_converted}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi

    # Python: Phase 2g - Async pattern linting with flake8-async
    # Detects missing await checkpoints, timeout parameter issues, etc.
    if command -v uv >/dev/null 2>&1; then
      async_output=$(uv run flake8 --select=ASYNC "${file_path}" 2>/dev/null || true)
      if [[ -n "${async_output}" ]]; then
        # shellcheck disable=SC2016
        async_json=$(echo "${async_output}" | while IFS= read -r line; do
          line_num=$(echo "${line}" | sed -E 's/^[^:]*:([0-9]+):[0-9]+: .*/\1/')
          col_num=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:([0-9]+): .*/\1/')
          code=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:[0-9]+: ([A-Z0-9]+) .*/\1/')
          msg=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:[0-9]+: [A-Z0-9]+ (.*)/\1/')
          jaq -n --arg l "${line_num}" --arg c "${col_num}" --arg cd "${code}" \
            --arg m "${msg}" \
            '{line:($l|tonumber),column:($c|tonumber),code:$cd,message:$m,linter:"flake8-async"}'
        done | jaq -s '.') || async_json="[]"
        if [[ -n "${async_json}" ]]; then
          _merged=$(echo "${collected_violations}" \
            "${async_json}" | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi
    ;;

  *.sh | *.bash)
    is_language_enabled "shell" || exit_json

    # Shell: Phase 1 - Auto-format with shfmt
    if is_auto_format_enabled && command -v shfmt >/dev/null 2>&1; then
      # Format shell script (indentation, spacing)
      # Using -i 2 for 2-space indent, -ci for case indent, -bn for binary ops
      shfmt -w -i 2 -ci -bn "${file_path}" 2>/dev/null || true
    fi

    # Shell: Phase 2 - Collect semantic issues with ShellCheck
    if command -v shellcheck >/dev/null 2>&1; then
      shellcheck_output=$(shellcheck -f json "${file_path}" 2>/dev/null || true)
      if [[ -n "${shellcheck_output}" ]] && [[ "${shellcheck_output}" != "[]" ]]; then
        # Convert shellcheck JSON to standard format and merge
        sc_converted=$(echo "${shellcheck_output}" | jaq '[.[] | {
          line: .line,
          column: .column,
          code: ("SC" + (.code | tostring)),
          message: .message,
          linter: "shellcheck"
        }]' 2>/dev/null) || sc_converted="[]"
        _merged=$(echo "${collected_violations}" "${sc_converted}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi
    ;;

  *.yml | *.yaml)
    is_language_enabled "yaml" || exit_json

    # YAML: yamllint - collect all issues
    if command -v yamllint >/dev/null 2>&1; then
      yamllint_output=$(yamllint -f parsable "${file_path}" 2>/dev/null || true)
      if [[ -n "${yamllint_output}" ]]; then
        # Convert yamllint parsable format to JSON (file:line:col: [level] message (code))
        # shellcheck disable=SC2016
        yaml_json=$(echo "${yamllint_output}" | while IFS= read -r line; do
          line_num=$(echo "${line}" | sed -E 's/^[^:]*:([0-9]+):[0-9]+: .*/\1/')
          col_num=$(echo "${line}" | sed -E 's/^[^:]*:[0-9]+:([0-9]+): .*/\1/')
          msg=$(echo "${line}" | sed -E 's/.*\[[a-z]+\] ([^(]+).*/\1/' | sed 's/ *$//')
          code=$(echo "${line}" | sed -E 's/.*\(([^)]+)\).*/\1/' || echo "unknown")
          jaq -n --arg l "${line_num}" --arg c "${col_num}" --arg cd "${code}" --arg m "${msg}" \
            '{line:($l|tonumber),column:($c|tonumber),code:$cd,message:$m,linter:"yamllint"}'
        done | jaq -s '.') || yaml_json="[]"
        if [[ -n "${yaml_json}" ]]; then
          _merged=$(echo "${collected_violations}" "${yaml_json}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi
    ;;

  *.json)
    is_language_enabled "json" || exit_json

    # JSON: Phase 1 - Validate syntax first
    json_error=$(jaq empty "${file_path}" 2>&1) || true
    if [[ -n "${json_error}" ]]; then
      # Collect JSON syntax error
      # shellcheck disable=SC2016 # $m is a jaq variable, not shell
      json_violation=$(jaq -n --arg m "${json_error}" \
        '[{line:1,column:1,code:"JSON_SYNTAX",message:$m,linter:"jaq"}]') || json_violation="[]"
      _merged=$(echo "${collected_violations}" "${json_violation}" \
        | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
      [[ -n "${_merged}" ]] && collected_violations="${_merged}"
      has_issues=true
    else
      # JSON: Phase 2 - Auto-format valid JSON
      # Use Biome if TS enabled and available (D6), fallback to jaq pretty-print
      if is_auto_format_enabled; then
        json_formatted=false
        if is_typescript_enabled; then
          _biome_cmd=$(detect_biome 2>/dev/null) || _biome_cmd=""
          if [[ -n "${_biome_cmd}" ]]; then
            ${_biome_cmd} format --write "${file_path}" >/dev/null 2>&1 && json_formatted=true
          fi
        fi
        if [[ "${json_formatted}" == "false" ]]; then
          tmp_file=$(mktemp) || true
          if [[ -n "${tmp_file}" ]] && jaq '.' "${file_path}" >"${tmp_file}" 2>/dev/null; then
            if ! cmp -s "${file_path}" "${tmp_file}"; then
              mv "${tmp_file}" "${file_path}"
            else
              rm -f "${tmp_file}"
            fi
          else
            rm -f "${tmp_file}" 2>/dev/null || true
          fi
        fi
      fi
    fi
    ;;

  Dockerfile | Dockerfile.* | */Dockerfile | */Dockerfile.* | *.dockerfile | *.Dockerfile)
    is_language_enabled "dockerfile" || exit_json

    # Dockerfile: hadolint - collect all issues
    # Requires hadolint >= 2.12.0 for disable-ignore-pragma support
    if command -v hadolint >/dev/null 2>&1; then
      # Version check (warn if too old, don't block)
      hadolint_version=$(hadolint --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1) || hadolint_version=""
      if [[ -n "${hadolint_version}" ]]; then
        major="${hadolint_version%%.*}"
        minor="${hadolint_version#*.}"
        if [[ "${major}" -lt 2 ]] || { [[ "${major}" -eq 2 ]] && [[ "${minor}" -lt 12 ]]; }; then
          echo "[hook:warning] hadolint ${hadolint_version} < 2.12.0 (some features may not work)" >&2
        fi
      fi
      hadolint_output=$(hadolint --no-color -f json "${file_path}" 2>/dev/null || true)
      if [[ -n "${hadolint_output}" ]] && [[ "${hadolint_output}" != "[]" ]]; then
        # Convert hadolint JSON to standard format and merge
        hl_converted=$(echo "${hadolint_output}" | jaq '[.[] | {
          line: .line,
          column: .column,
          code: .code,
          message: .message,
          linter: "hadolint"
        }]' 2>/dev/null) || hl_converted="[]"
        _merged=$(echo "${collected_violations}" "${hl_converted}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi
    ;;

  *.toml)
    is_language_enabled "toml" || exit_json

    # NOTE: taplo.toml include pattern limits validation to project files.
    # Files outside project directory are silently excluded (known design).
    # TOML: Phase 1 - Auto-format
    if is_auto_format_enabled && command -v taplo >/dev/null 2>&1; then
      # Format TOML in-place (fixes spacing, alignment)
      RUST_LOG=error taplo fmt "${file_path}" 2>/dev/null || true
    fi

    if command -v taplo >/dev/null 2>&1; then
      # TOML: Phase 2 - Check for syntax errors (can't be auto-fixed)
      taplo_check=$(RUST_LOG=error taplo check "${file_path}" 2>&1) || true
      if [[ -n "${taplo_check}" ]]; then
        # Collect TOML syntax error
        # shellcheck disable=SC2016
        toml_violation=$(jaq -n --arg m "${taplo_check}" \
          '[{line:1,column:1,code:"TOML_SYNTAX",message:$m,linter:"taplo"}]') || toml_violation="[]"
        _merged=$(echo "${collected_violations}" "${toml_violation}" \
          | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
        [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        has_issues=true
      fi
    fi
    ;;

  *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.mts | *.cts | *.css | *.vue | *.svelte | *.astro)
    is_typescript_enabled || exit_json
    handle_typescript "${file_path}"
    ;;

  *.md | *.mdx)
    is_language_enabled "markdown" || exit_json

    # Markdown: Phase 1 - Auto-fix what we can
    if command -v markdownlint-cli2 >/dev/null 2>&1; then
      # --no-globs: Disable config globs, lint only the specific file
      # Without this, markdownlint merges globs from .markdownlint-cli2.jsonc
      # noBanner+noProgress in .markdownlint-cli2.jsonc suppress verbose output
      # Phase 1: Auto-fix (silently fixes what it can, outputs only unfixable issues)
      if is_auto_format_enabled; then
        markdownlint-cli2 --no-globs --fix "${file_path}" >/dev/null 2>&1 || true
      fi

      # Phase 2: Collect remaining unfixable issues for delegation
      markdownlint_output=$(markdownlint-cli2 --no-globs "${file_path}" 2>&1 || true)

      # Count remaining violations (lines matching file:line pattern)
      # grep -c exits 1 on no matches but still outputs 0, so use || true to ignore exit code
      violation_count=$(echo "${markdownlint_output}" | grep -cE "^[^:]+:[0-9]+" || true)
      [[ -z "${violation_count}" ]] && violation_count=0

      # Only collect if there are actual errors
      if [[ -n "${markdownlint_output}" ]] && ! echo "${markdownlint_output}" | grep -q "Summary: 0 error"; then
        # Convert markdownlint output to JSON (file:line:col MD### message)
        # shellcheck disable=SC2016
        md_json=$(echo "${markdownlint_output}" | grep -E "^[^:]+:[0-9]+" | while IFS= read -r line; do
          line_num=$(echo "${line}" | sed -E 's/[^:]+:([0-9]+).*/\1/')
          code=$(echo "${line}" | sed -E 's/.*[[:space:]](MD[0-9]+).*/\1/' || echo "MD000")
          msg=$(echo "${line}" | sed -E 's/.*MD[0-9]+[^[:alnum:]]*(.+)/\1/' | sed 's/^ *//')
          jaq -n --arg l "${line_num}" --arg cd "${code}" --arg m "${msg}" \
            '{line:($l|tonumber),column:1,code:$cd,message:$m,linter:"markdownlint"}'
        done | jaq -s '.') || md_json="[]"
        if [[ -n "${md_json}" ]] && [[ "${md_json}" != "[]" ]]; then
          _merged=$(echo "${collected_violations}" "${md_json}" \
            | jaq -s '.[0] + .[1]' 2>/dev/null) || _merged=""
          [[ -n "${_merged}" ]] && collected_violations="${_merged}"
        fi
        has_issues=true
      fi
    fi
    ;;
  *)
    # Unsupported file type - no linting available
    ;;
esac

# ============================================================================
# DELEGATION AND EXIT LOGIC
# ============================================================================

# If no issues, exit clean
if [[ "${has_issues}" = false ]]; then
  exit_json
fi

# Calculate model selection for debugging/testing
# This runs before HOOK_SKIP_SUBPROCESS check so tests can verify model selection
if [[ "${HOOK_DEBUG_MODEL:-}" == "1" ]]; then
  # Align with real delegation: filter to D-only subset for Python docstring cases
  debug_violations_json="${collected_violations}"
  if [[ "${file_type}" == "python" ]] && echo "${collected_violations}" | jaq -e '[.[] | select(.code | test("^D[0-9]+$"))] | length > 0' >/dev/null 2>&1; then
    debug_violations_json=$(echo "${collected_violations}" | jaq -c '[.[] | select(.code | test("^D[0-9]+$"))]' 2>/dev/null) || debug_violations_json="${collected_violations}"
  fi

  count=$(echo "${debug_violations_json}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")

  debug_has_opus_codes="false"
  if echo "${debug_violations_json}" | jaq -e '[.[] | select(.code | test("'"${OPUS_CODE_PATTERN}"'"))] | length > 0' >/dev/null 2>&1; then
    debug_has_opus_codes="true"
  fi

  debug_has_sonnet_codes="false"
  if echo "${debug_violations_json}" | jaq -e '[.[] | select(.code | test("'"${SONNET_CODE_PATTERN}"'"))] | length > 0' >/dev/null 2>&1; then
    debug_has_sonnet_codes="true"
  fi

  debug_model="haiku"
  if [[ "${debug_has_sonnet_codes}" == "true" ]]; then
    debug_model="sonnet"
  fi
  if [[ "${debug_has_opus_codes}" == "true" ]] || [[ "${count}" -gt "${VOLUME_THRESHOLD}" ]]; then
    debug_model="opus"
  fi

  echo "[hook:model] ${debug_model}" >&2
fi

# Testing mode: skip subprocess and report violations directly
# Usage: HOOK_SKIP_SUBPROCESS=1 ./multi_linter.sh
if [[ "${HOOK_SKIP_SUBPROCESS:-}" == "1" ]]; then
  skip_count=$(echo "${collected_violations}" | jaq 'length' 2>/dev/null | head -n1 || echo "0")
  if [[ "${skip_count}" -eq 0 ]]; then
    exit_json
  fi
  echo "[hook] ${collected_violations}" >&2
  exit 2
fi

# Delegate to subprocess to fix violations
if is_subprocess_enabled && [[ -z "${HOOK_SKIP_SUBPROCESS:-}" ]]; then
  spawn_fix_subprocess "${file_path}" "${collected_violations}" "${file_type}"
fi

# Verify: re-run Phase 1 + Phase 2
_verify_started=${SECONDS}
hook_diag "phase=verify_start tool=${tool_name} file=${file_path} ftype=${file_type}"

_p1_started=${SECONDS}
hook_diag "phase=rerun_phase1_start tool=${tool_name} file=${file_path} ftype=${file_type}"
rerun_phase1 "${file_path}" "${file_type}"
hook_diag "phase=rerun_phase1_end tool=${tool_name} file=${file_path} ftype=${file_type} duration_s=$((SECONDS - _p1_started))"

_p2_started=${SECONDS}
hook_diag "phase=rerun_phase2_start tool=${tool_name} file=${file_path} ftype=${file_type}"
rerun_phase2 "${file_path}" "${file_type}"
_remaining_codes=$(echo "${RERUN_PHASE2_RAW:-[]}" | jaq -r '[.[].code] | sort | unique | join(",")' 2>/dev/null || echo "")
hook_diag "phase=rerun_phase2_end tool=${tool_name} file=${file_path} ftype=${file_type} duration_s=$((SECONDS - _p2_started)) remaining_count=${RERUN_PHASE2_COUNT} remaining_codes=${_remaining_codes}"

remaining="${RERUN_PHASE2_COUNT}"
hook_diag "phase=verify_end tool=${tool_name} file=${file_path} ftype=${file_type} remaining_count=${remaining} remaining_codes=${_remaining_codes} duration_s=$((SECONDS - _verify_started))"

if [[ "${remaining}" -eq 0 ]]; then
  hook_diag "phase=resolved tool=${tool_name} file=${file_path} ftype=${file_type} remaining=0"
  exit_json "Phase 3 resolved all violations."
else
  extract_violation_codes "${file_type}"
  _base_name=$(basename "${file_path}")
  if [[ -n "${VIOLATION_CODES}" ]]; then
    hook_json "${remaining} violation(s) in ${_base_name}: ${VIOLATION_CODES}. Fix them."
  else
    hook_json "${remaining} violation(s) in ${_base_name}. Fix them."
  fi
  hook_diag "phase=feedback_loop tool=${tool_name} file=${file_path} ftype=${file_type} remaining_count=${remaining} remaining_codes=${VIOLATION_CODES:-}"
  echo "[hook:feedback-loop] delivered ${remaining} for ${file_path}" >&2
  exit 2
fi
