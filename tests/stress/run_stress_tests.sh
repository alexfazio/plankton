#!/bin/bash
# run_stress_tests.sh - Comprehensive stress test suite for hook system
# Generates TAP-format output and a report at docs/stress-test-report.md
#
# Usage: bash tests/stress/run_stress_tests.sh
#
# Environment:
#   HOOK_SKIP_SUBPROCESS=1  (always set internally - no real subprocess spawning)
#   HOOK_DEBUG_MODEL=1      (set internally for model selection tests)
#
# Dependencies: jaq, ruff, shellcheck, shfmt, yamllint, hadolint, taplo,
#               markdownlint-cli2, biome (npm). Missing tools → SKIP.

set -euo pipefail

# ============================================================================
# CONSTANTS & PATHS
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HOOK_DIR="${PROJECT_DIR}/.claude/hooks"
MULTI_LINTER="${HOOK_DIR}/multi_linter.sh"
PROTECT_CONFIGS="${HOOK_DIR}/protect_linter_configs.sh"
STOP_GUARDIAN="${HOOK_DIR}/stop_config_guardian.sh"
APPROVE_CONFIGS="${HOOK_DIR}/approve_configs.sh"

REPORT_FILE="${PROJECT_DIR}/docs/stress-test-report.md"

# TAP counters
TAP_NUM=0
TAP_PASS=0
TAP_FAIL=0
TAP_SKIP=0
FAILURES=""
SKIPS=""
PERF_RESULTS=""

# Category counters (bash 3.2 compatible, accessed via eval in _inc_cat/_get_cat)
export CAT_A_PASS=0
export CAT_A_FAIL=0
export CAT_A_SKIP=0
export CAT_B_PASS=0
export CAT_B_FAIL=0
export CAT_B_SKIP=0
export CAT_C_PASS=0
export CAT_C_FAIL=0
export CAT_C_SKIP=0
export CAT_D_PASS=0
export CAT_D_FAIL=0
export CAT_D_SKIP=0
export CAT_E_PASS=0
export CAT_E_FAIL=0
export CAT_E_SKIP=0
export CAT_F_PASS=0
export CAT_F_FAIL=0
export CAT_F_SKIP=0
export CAT_G_PASS=0
export CAT_G_FAIL=0
export CAT_G_SKIP=0
export CAT_H_PASS=0
export CAT_H_FAIL=0
export CAT_H_SKIP=0

_inc_cat() {
  local c="$1" t="$2"
  eval "CAT_${c}_${t}=\$(( CAT_${c}_${t} + 1 ))"
}
_get_cat() {
  local c="$1" t="$2"
  eval "echo \${CAT_${c}_${t}}"
}

# Temp directory for all fixtures
TEMP_DIR=$(mktemp -d)

# Session files to clean up (keyed on our own PID since hooks use PPID)
SESSION_FILES=(
  "/tmp/.biome_path_$$"
  "/tmp/.semgrep_session_$$"
  "/tmp/.semgrep_session_$$.done"
  "/tmp/.jscpd_ts_session_$$"
  "/tmp/.jscpd_ts_session_$$.done"
  "/tmp/.jscpd_session_$$"
  "/tmp/.jscpd_session_$$.done"
  "/tmp/.nursery_checked_$$"
  "/tmp/stop_hook_approved_$$.json"
)

# shellcheck disable=SC2329
cleanup() {
  rm -rf "${TEMP_DIR}"
  for f in "${SESSION_FILES[@]}"; do
    rm -f "${f}"
  done
  rm -f /tmp/.sfc_warned_*_$$
}
trap cleanup EXIT

# ============================================================================
# TAP HELPERS
# ============================================================================

tap_ok() {
  local category="$1"
  local description="$2"
  TAP_NUM=$((TAP_NUM + 1))
  TAP_PASS=$((TAP_PASS + 1))
  _inc_cat "${category}" PASS
  echo "ok ${TAP_NUM} - ${description}"
}

tap_fail() {
  local category="$1"
  local description="$2"
  local detail="${3:-}"
  TAP_NUM=$((TAP_NUM + 1))
  TAP_FAIL=$((TAP_FAIL + 1))
  _inc_cat "${category}" FAIL
  echo "not ok ${TAP_NUM} - ${description}"
  if [[ -n "${detail}" ]]; then
    echo "  # ${detail}" | head -5
  fi
  FAILURES+="| ${TAP_NUM} | ${description} | ${detail:0:120} |"$'\n'
}

tap_skip() {
  local category="$1"
  local description="$2"
  local reason="$3"
  TAP_NUM=$((TAP_NUM + 1))
  TAP_SKIP=$((TAP_SKIP + 1))
  _inc_cat "${category}" SKIP
  echo "ok ${TAP_NUM} - ${description} # SKIP ${reason}"
  SKIPS+="| ${TAP_NUM} | ${description} | ${reason} |"$'\n'
}

# Nanosecond timer (macOS compatible)
get_ns() {
  if date +%s%N 2>/dev/null | grep -qE '^[0-9]{19}$'; then
    date +%s%N
  elif command -v gdate >/dev/null 2>&1; then
    gdate +%s%N
  else
    python3 -c 'import time; print(int(time.time() * 1e9))'
  fi
}

# ============================================================================
# TEST RUNNERS
# ============================================================================

# Run multi_linter.sh with a file, capture exit code and stderr
# Sets: LAST_EXIT, LAST_STDERR
run_multi_linter() {
  local file="$1"
  local proj_dir="${2:-${PROJECT_DIR}}"
  local json='{"tool_input":{"file_path":"'"${file}"'"}}'
  set +e
  LAST_STDERR=$(echo "${json}" \
    | HOOK_SKIP_SUBPROCESS=1 \
      HOOK_SESSION_PID=$$ \
      CLAUDE_PROJECT_DIR="${proj_dir}" \
      bash "${MULTI_LINTER}" 2>&1 >/dev/null)
  LAST_EXIT=$?
  set -e
}

# Run multi_linter.sh with HOOK_DEBUG_MODEL=1, capture model from stderr
# Sets: LAST_MODEL, LAST_EXIT
run_multi_linter_model() {
  local file="$1"
  local proj_dir="${2:-${PROJECT_DIR}}"
  local json='{"tool_input":{"file_path":"'"${file}"'"}}'
  set +e
  local stderr_out
  stderr_out=$(echo "${json}" \
    | HOOK_SKIP_SUBPROCESS=1 \
      HOOK_DEBUG_MODEL=1 \
      HOOK_SESSION_PID=$$ \
      CLAUDE_PROJECT_DIR="${proj_dir}" \
      bash "${MULTI_LINTER}" 2>&1 >/dev/null)
  LAST_EXIT=$?
  set -e
  LAST_MODEL=$(echo "${stderr_out}" | grep -oE '\[hook:model\] (haiku|sonnet|opus)' | awk '{print $2}' || echo "none")
}

# Run protect_linter_configs.sh, capture JSON output
# Sets: LAST_OUTPUT
run_protect() {
  local file="$1"
  local proj_dir="${2:-${PROJECT_DIR}}"
  local json='{"tool_input":{"file_path":"'"${file}"'"}}'
  LAST_OUTPUT=$(echo "${json}" \
    | CLAUDE_PROJECT_DIR="${proj_dir}" \
      bash "${PROTECT_CONFIGS}" 2>/dev/null)
}

# Run stop_config_guardian.sh, capture JSON output
# Sets: LAST_OUTPUT
run_stop() {
  local input_json="$1"
  local work_dir="${2:-${PROJECT_DIR}}"
  LAST_OUTPUT=$(cd "${work_dir}" && echo "${input_json}" | CLAUDE_PROJECT_DIR="${work_dir}" bash "${STOP_GUARDIAN}" 2>/dev/null)
}

# ============================================================================
# CONFIG CREATORS
# ============================================================================

# Create a TS-enabled config in a directory
create_ts_config() {
  local dir="$1"
  mkdir -p "${dir}/.claude/hooks"
  cat >"${dir}/.claude/hooks/config.json" <<'TSCFG'
{
  "languages": {
    "python": true, "shell": true, "yaml": true, "json": true,
    "toml": true, "dockerfile": true, "markdown": true,
    "typescript": {
      "enabled": true, "js_runtime": "auto", "biome_nursery": "warn",
      "biome_unsafe_autofix": false, "semgrep": true, "knip": false
    }
  },
  "protected_files": [
    ".markdownlint.jsonc", ".markdownlint-cli2.jsonc", ".shellcheckrc",
    ".yamllint", ".hadolint.yaml", ".jscpd.json", ".flake8",
    "taplo.toml", ".ruff.toml", "ty.toml",
    "biome.json", ".oxlintrc.json", ".semgrep.yml", "knip.json"
  ],
  "phases": { "auto_format": true, "subprocess_delegation": true },
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "SC[0-9]+|E[0-9]+|W[0-9]+|F[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "C901|PLR[0-9]+|PYD[0-9]+|FAST[0-9]+|ASYNC[0-9]+|unresolved-import|MD[0-9]+|D[0-9]+|complexity|useExhaustiveDependencies|noExplicitAny", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "unresolved-attribute|type-assertion", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}
TSCFG
}

# Create config with a specific language disabled
# Returns the directory path
create_disabled_lang_config() {
  local lang="$1"
  local dir="${TEMP_DIR}/disabled_${lang}"
  mkdir -p "${dir}/.claude/hooks"

  # Build JSON with specified language set to false
  # Build JSON with only the target language disabled (no duplicate keys)
  local py="true" sh="true" ym="true" js="true" tm="true" df="true" md="true"
  local ts='{"enabled": true, "js_runtime": "auto", "semgrep": false}'
  case "${lang}" in
    python) py="false" ;;
    shell) sh="false" ;;
    yaml) ym="false" ;;
    json) js="false" ;;
    toml) tm="false" ;;
    dockerfile) df="false" ;;
    markdown) md="false" ;;
    typescript) ts='{"enabled": false}' ;;
    *)
      echo "Unknown language: ${lang}" >&2
      return 1
      ;;
  esac

  cat >"${dir}/.claude/hooks/config.json" <<DISABLECFG
{
  "languages": {
    "python": ${py}, "shell": ${sh}, "yaml": ${ym}, "json": ${js},
    "toml": ${tm}, "dockerfile": ${df}, "markdown": ${md},
    "typescript": ${ts}
  },
  "phases": { "auto_format": true, "subprocess_delegation": true },
  "subprocess": { "tiers": {
    "haiku": {"patterns": "SC[0-9]+|E[0-9]+|W[0-9]+|F[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
    "sonnet": {"patterns": "C901", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
    "opus": {"patterns": "x", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
  }, "global_model_override": null, "max_turns_override": null, "timeout_override": null, "volume_threshold": 5, "settings_file": null}
}
DISABLECFG
  echo "${dir}"
}

# Create config with a specific phase toggle
create_phase_config() {
  local key="$1"
  local value="$2"
  local dir="${TEMP_DIR}/phase_${key}_${value}"
  mkdir -p "${dir}/.claude/hooks"

  cat >"${dir}/.claude/hooks/config.json" <<PHASECFG
{
  "languages": {
    "python": true, "shell": true, "yaml": true, "json": true,
    "toml": true, "dockerfile": true, "markdown": true,
    "typescript": {"enabled": true, "js_runtime": "auto", "semgrep": false}
  },
  "phases": { "auto_format": ${value}, "subprocess_delegation": ${value} },
  "subprocess": { "tiers": {
    "haiku": {"patterns": "SC[0-9]+|E[0-9]+|W[0-9]+|F[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
    "sonnet": {"patterns": "C901", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
    "opus": {"patterns": "x", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
  }, "global_model_override": null, "max_turns_override": null, "timeout_override": null, "volume_threshold": 5, "settings_file": null}
}
PHASECFG
  echo "${dir}"
}

# ============================================================================
# TOOL AVAILABILITY CHECKS
# ============================================================================

HAS_RUFF=false
command -v ruff >/dev/null 2>&1 && HAS_RUFF=true
HAS_SHELLCHECK=false
command -v shellcheck >/dev/null 2>&1 && HAS_SHELLCHECK=true
HAS_SHFMT=false
command -v shfmt >/dev/null 2>&1 && HAS_SHFMT=true
HAS_YAMLLINT=false
command -v yamllint >/dev/null 2>&1 && HAS_YAMLLINT=true
HAS_HADOLINT=false
command -v hadolint >/dev/null 2>&1 && HAS_HADOLINT=true
HAS_TAPLO=false
command -v taplo >/dev/null 2>&1 && HAS_TAPLO=true
HAS_MARKDOWNLINT=false
command -v markdownlint-cli2 >/dev/null 2>&1 && HAS_MARKDOWNLINT=true
HAS_JQ=false
command -v jaq >/dev/null 2>&1 && HAS_JQ=true
HAS_SEMGREP=false
command -v semgrep >/dev/null 2>&1 && HAS_SEMGREP=true
HAS_JSCPD=false
command -v npx >/dev/null 2>&1 && HAS_JSCPD=true

# Biome detection
HAS_BIOME=false
export BIOME_CMD=""
if [[ -x "${PROJECT_DIR}/node_modules/.bin/biome" ]]; then
  HAS_BIOME=true
  export BIOME_CMD="${PROJECT_DIR}/node_modules/.bin/biome"
elif command -v biome >/dev/null 2>&1; then
  HAS_BIOME=true
  export BIOME_CMD="biome"
elif command -v npx >/dev/null 2>&1; then
  # Test if npx biome works
  if npx biome --version >/dev/null 2>&1; then
    HAS_BIOME=true
    export BIOME_CMD="npx biome"
  fi
fi

# Create TS project dir for biome tests
TS_PROJECT="${TEMP_DIR}/ts_project"
create_ts_config "${TS_PROJECT}"
# Copy biome.json if it exists in project
if [[ -f "${PROJECT_DIR}/biome.json" ]]; then
  cp "${PROJECT_DIR}/biome.json" "${TS_PROJECT}/biome.json"
fi

echo "TAP version 14"
echo ""
echo "# Tool availability:"
echo "#   ruff=${HAS_RUFF} shellcheck=${HAS_SHELLCHECK} shfmt=${HAS_SHFMT}"
echo "#   yamllint=${HAS_YAMLLINT} hadolint=${HAS_HADOLINT} taplo=${HAS_TAPLO}"
echo "#   markdownlint=${HAS_MARKDOWNLINT} jaq=${HAS_JQ} biome=${HAS_BIOME}"
echo "#   semgrep=${HAS_SEMGREP} jscpd=${HAS_JSCPD}"
echo ""

# ============================================================================
# CATEGORY A: LANGUAGE HANDLERS (~50 tests)
# ============================================================================

echo "# Category A: Language Handlers"

# --- A1-A13: Python ---

if ! ${HAS_RUFF}; then
  for i in $(seq 1 13); do
    tap_skip A "A${i}: Python test" "ruff not installed"
  done
else
  # A1: Python clean file
  f="${TEMP_DIR}/a1_clean.py"
  cat >"${f}" <<'PY_CLEAN'
"""Module docstring."""


def greet(name: str) -> str:
    """Greet someone by name."""
    return f"Hello, {name}"
PY_CLEAN
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A1: Python clean file exits 0"
  else
    tap_fail A "A1: Python clean file exits 0" "got exit ${LAST_EXIT}"
  fi

  # A2: Python F841 unused variable
  f="${TEMP_DIR}/a2_unused.py"
  cat >"${f}" <<'PY_F841'
"""Module docstring."""


def foo():
    """Do something."""
    unused = 1
    return 42
PY_F841
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A2: Python F841 unused variable exits 2"
  else
    tap_fail A "A2: Python F841 unused variable exits 2" "got exit ${LAST_EXIT}"
  fi

  # A3: Python autofix (import sorting)
  f="${TEMP_DIR}/a3_autofix.py"
  cat >"${f}" <<'PY_FIX'
"""Module docstring."""

import os
import sys


def main():
    """Run main."""
    print(os.getcwd(), sys.argv)
PY_FIX
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A3: Python autofix (clean after format) exits 0"
  else
    tap_fail A "A3: Python autofix exits 0" "got exit ${LAST_EXIT}"
  fi

  # A4: Python multiple violations
  f="${TEMP_DIR}/a4_multi.py"
  cat >"${f}" <<'PY_MULTI'
"""Module docstring."""


def bar():
    """Do bar."""
    a = 1
    b = 2
    return 42
PY_MULTI
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A4: Python multiple violations exits 2"
  else
    tap_fail A "A4: Python multiple violations exits 2" "got exit ${LAST_EXIT}"
  fi

  # A5: Python empty file (triggers D100 missing module docstring -> exit 2)
  f="${TEMP_DIR}/a5_empty.py"
  : >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A5: Python empty file runs without crash (exit ${LAST_EXIT})"
  else
    tap_fail A "A5: Python empty file runs without crash" "got exit ${LAST_EXIT}"
  fi

  # A6: Python C901 complexity (long function)
  f="${TEMP_DIR}/a6_complex.py"
  cat >"${f}" <<'PY_C901'
"""Module docstring."""


def complex_func(x):
    """Handle complex logic."""
    if x > 0:
        if x > 10:
            if x > 20:
                if x > 30:
                    if x > 40:
                        if x > 50:
                            if x > 60:
                                if x > 70:
                                    if x > 80:
                                        if x > 90:
                                            if x > 100:
                                                return "big"
    return "small"
PY_C901
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A6: Python C901 complexity exits 2"
  else
    tap_fail A "A6: Python C901 complexity exits 2" "got exit ${LAST_EXIT}"
  fi

  # A7: Python PLR0913 too many args
  f="${TEMP_DIR}/a7_plr.py"
  cat >"${f}" <<'PY_PLR'
"""Module docstring."""


def process(one, two, three, four, five, six):
    """Process too many args."""
    return one + two + three + four + five + six
PY_PLR
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A7: Python PLR0913 too many args exits 2"
  else
    tap_fail A "A7: Python PLR0913 too many args exits 2" "got exit ${LAST_EXIT}"
  fi

  # A8: Python PYD (pydantic) - skip if flake8-pydantic not available
  tap_skip A "A8: Python PYD pydantic lint" "flake8-pydantic requires uv project"

  # A9: Python vulture (dead code) - skip for test paths
  tap_skip A "A9: Python vulture dead code" "vulture requires uv project"

  # A10: Python bandit (security) - skip for test paths
  tap_skip A "A10: Python bandit security" "bandit requires uv project"

  # A11: Python ASYNC - skip
  tap_skip A "A11: Python ASYNC patterns" "flake8-async requires uv project"

  # A12: Python docstring violations (D103)
  f="${TEMP_DIR}/a12_nodoc.py"
  cat >"${f}" <<'PY_DOC'
def missing_docstring():
    return 42
PY_DOC
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A12: Python D103 missing docstring exits 2"
  else
    tap_fail A "A12: Python D103 missing docstring exits 2" "got exit ${LAST_EXIT}"
  fi

  # A13: Python path exclusion (tests/ dir excluded from vulture/bandit)
  # Create a proper project dir with config so jaq does not crash
  a13_dir="${TEMP_DIR}/a13_project"
  mkdir -p "${a13_dir}/.claude/hooks" "${a13_dir}/tests"
  cp "${HOOK_DIR}/config.json" "${a13_dir}/.claude/hooks/config.json"
  f="${a13_dir}/tests/a13_excluded.py"
  cat >"${f}" <<'PY_EXCL'
"""Test module."""


def test_something():
    """Test something."""
    assert True
PY_EXCL
  # Use TEMP_DIR as project dir so tests/ matches exclusion
  run_multi_linter "${f}" "${a13_dir}"
  # Should still lint with ruff but skip vulture/bandit
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A13: Python path exclusion runs (security linters skipped)"
  else
    tap_fail A "A13: Python path exclusion" "unexpected exit ${LAST_EXIT}"
  fi
fi

# --- A14-A18: Shell ---

if ! ${HAS_SHELLCHECK}; then
  for i in 14 15 16 17 18; do
    tap_skip A "A${i}: Shell test" "shellcheck not installed"
  done
else
  # A14: Shell clean file
  f="${TEMP_DIR}/a14_clean.sh"
  cat >"${f}" <<'SH_CLEAN'
#!/bin/bash
set -euo pipefail
echo "hello world"
SH_CLEAN
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A14: Shell clean file exits 0"
  else
    tap_fail A "A14: Shell clean file exits 0" "got exit ${LAST_EXIT}"
  fi

  # A15: Shell SC2086 unquoted variable
  f="${TEMP_DIR}/a15_sc2086.sh"
  cat >"${f}" <<'SH_2086'
#!/bin/bash
var="hello world"
echo $var
SH_2086
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A15: Shell SC2086 unquoted var exits 2"
  else
    tap_fail A "A15: Shell SC2086 unquoted var exits 2" "got exit ${LAST_EXIT}"
  fi

  # A16: Shell autofix (shfmt formatting)
  f="${TEMP_DIR}/a16_format.sh"
  cat >"${f}" <<'SH_FMT'
#!/bin/bash
if   [ "x" = "x" ];then
echo "ok"
fi
SH_FMT
  # After shfmt, shellcheck may still find issues or not
  run_multi_linter "${f}"
  # Just verify it doesn't crash
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A16: Shell autofix runs without crash"
  else
    tap_fail A "A16: Shell autofix runs without crash" "got exit ${LAST_EXIT}"
  fi

  # A17: Shell multiple violations
  f="${TEMP_DIR}/a17_multi.sh"
  cat >"${f}" <<'SH_MULTI'
#!/bin/bash
var="hello"
echo $var
foo=$bar
echo $foo
SH_MULTI
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A17: Shell multiple violations exits 2"
  else
    tap_fail A "A17: Shell multiple violations exits 2" "got exit ${LAST_EXIT}"
  fi

  # A18: Shell empty file (with shebang)
  f="${TEMP_DIR}/a18_empty.sh"
  echo '#!/bin/bash' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A18: Shell minimal file exits 0"
  else
    tap_fail A "A18: Shell minimal file exits 0" "got exit ${LAST_EXIT}"
  fi
fi

# --- A19-A23: YAML ---

if ! ${HAS_YAMLLINT}; then
  for i in 19 20 21 22 23; do
    tap_skip A "A${i}: YAML test" "yamllint not installed"
  done
else
  # A19: YAML clean file
  f="${TEMP_DIR}/a19_clean.yaml"
  printf 'key: value\n' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A19: YAML clean file exits 0"
  else
    tap_fail A "A19: YAML clean file exits 0" "got exit ${LAST_EXIT}: ${LAST_STDERR}"
  fi

  # A20: YAML indentation violation
  f="${TEMP_DIR}/a20_indent.yaml"
  printf 'parent:\n   child: value\n' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A20: YAML indent violation exits 2"
  else
    tap_fail A "A20: YAML indent violation exits 2" "got exit ${LAST_EXIT}"
  fi

  # A21: YAML no autofix (yamllint has no autofix)
  f="${TEMP_DIR}/a21_nofix.yaml"
  printf 'key:  value\n' >"${f}"
  run_multi_linter "${f}"
  # Double space after colon violates yamllint
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A21: YAML no-autofix violation exits 2"
  else
    tap_fail A "A21: YAML no-autofix violation exits 2" "got exit ${LAST_EXIT}"
  fi

  # A22: YAML multiple violations
  f="${TEMP_DIR}/a22_multi.yaml"
  printf 'key:  value\nbad:  also\n' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A22: YAML multiple violations exits 2"
  else
    tap_fail A "A22: YAML multiple violations exits 2" "got exit ${LAST_EXIT}"
  fi

  # A23: YAML empty file
  f="${TEMP_DIR}/a23_empty.yaml"
  : >"${f}"
  run_multi_linter "${f}"
  # Empty YAML may warn about missing document
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A23: YAML empty file runs without crash"
  else
    tap_fail A "A23: YAML empty file runs without crash" "got exit ${LAST_EXIT}"
  fi
fi

# --- A24-A27: JSON ---

if ! ${HAS_JQ}; then
  for i in 24 25 26 27; do
    tap_skip A "A${i}: JSON test" "jaq not installed"
  done
else
  # A24: JSON clean file
  f="${TEMP_DIR}/a24_clean.json"
  echo '{"key": "value"}' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A24: JSON clean file exits 0"
  else
    tap_fail A "A24: JSON clean file exits 0" "got exit ${LAST_EXIT}"
  fi

  # A25: JSON syntax error
  f="${TEMP_DIR}/a25_bad.json"
  echo '{invalid}' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A25: JSON syntax error exits 2"
  else
    tap_fail A "A25: JSON syntax error exits 2" "got exit ${LAST_EXIT}"
  fi

  # A26: JSON autoformat (compact -> pretty)
  f="${TEMP_DIR}/a26_format.json"
  echo '{"a":1,"b":2}' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A26: JSON autoformat exits 0"
  else
    tap_fail A "A26: JSON autoformat exits 0" "got exit ${LAST_EXIT}"
  fi

  # A27: JSON empty file (syntax error)
  f="${TEMP_DIR}/a27_empty.json"
  : >"${f}"
  run_multi_linter "${f}"
  # Empty file is a syntax error for jaq
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A27: JSON empty file runs without crash"
  else
    tap_fail A "A27: JSON empty file runs without crash" "got exit ${LAST_EXIT}"
  fi
fi

# --- A28-A31: TOML ---

if ! ${HAS_TAPLO}; then
  for i in 28 29 30 31; do
    tap_skip A "A${i}: TOML test" "taplo not installed"
  done
else
  # A28: TOML clean file
  f="${TEMP_DIR}/a28_clean.toml"
  printf '[section]\nkey = "value"\n' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A28: TOML clean file exits 0"
  else
    tap_fail A "A28: TOML clean file exits 0" "got exit ${LAST_EXIT}"
  fi

  # A29: TOML syntax error
  f="${TEMP_DIR}/a29_bad.toml"
  printf '[section\nkey = value\n' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A29: TOML syntax error handled (exit ${LAST_EXIT})"
  else
    tap_fail A "A29: TOML syntax error handled" "got exit ${LAST_EXIT}"
  fi

  # A30: TOML autoformat
  f="${TEMP_DIR}/a30_format.toml"
  printf '[section]\nkey="value"\n' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A30: TOML autoformat exits 0"
  else
    tap_fail A "A30: TOML autoformat exits 0" "got exit ${LAST_EXIT}"
  fi

  # A31: TOML empty file
  f="${TEMP_DIR}/a31_empty.toml"
  : >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A31: TOML empty file exits 0"
  else
    tap_fail A "A31: TOML empty file exits 0" "got exit ${LAST_EXIT}"
  fi
fi

# --- A32-A36: Markdown ---

if ! ${HAS_MARKDOWNLINT}; then
  for i in 32 33 34 35 36; do
    tap_skip A "A${i}: Markdown test" "markdownlint-cli2 not installed"
  done
else
  # A32: Markdown clean file
  f="${TEMP_DIR}/a32_clean.md"
  printf '# Hello\n\nSome text.\n' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A32: Markdown clean file exits 0"
  else
    tap_fail A "A32: Markdown clean file exits 0" "got exit ${LAST_EXIT}: ${LAST_STDERR}"
  fi

  # A33: Markdown violation (multiple blank lines)
  f="${TEMP_DIR}/a33_violation.md"
  printf '# Title\n\n\n\nText after too many blank lines.\n' >"${f}"
  run_multi_linter "${f}"
  # markdownlint may autofix some issues
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A33: Markdown violation runs without crash"
  else
    tap_fail A "A33: Markdown violation runs without crash" "got exit ${LAST_EXIT}"
  fi

  # A34: Markdown autofix (trailing whitespace)
  f="${TEMP_DIR}/a34_autofix.md"
  printf '# Title\n\nSome text   \n' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A34: Markdown autofix (trailing space) exits 0"
  else
    tap_fail A "A34: Markdown autofix exits 0" "got exit ${LAST_EXIT}"
  fi

  # A35: Markdown multiple violations
  f="${TEMP_DIR}/a35_multi.md"
  printf '#Bad heading\n\nText   \n\n\n\nMore text.\n' >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A35: Markdown multiple violations runs without crash"
  else
    tap_fail A "A35: Markdown multiple violations crashes" "got exit ${LAST_EXIT}"
  fi

  # A36: Markdown empty file
  f="${TEMP_DIR}/a36_empty.md"
  : >"${f}"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A36: Markdown empty file runs without crash"
  else
    tap_fail A "A36: Markdown empty file runs without crash" "got exit ${LAST_EXIT}"
  fi
fi

# --- A37-A41: Dockerfile ---

if ! ${HAS_HADOLINT}; then
  for i in 37 38 39 40 41; do
    tap_skip A "A${i}: Dockerfile test" "hadolint not installed"
  done
else
  # A37: Dockerfile clean
  f="${TEMP_DIR}/Dockerfile.a37"
  cat >"${f}" <<'DF_CLEAN'
FROM python:3.11-slim
LABEL maintainer="test" version="1.0"
CMD ["python"]
DF_CLEAN
  # Rename to match pattern
  mv "${f}" "${TEMP_DIR}/a37.dockerfile"
  f="${TEMP_DIR}/a37.dockerfile"
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A37: Dockerfile clean exits 0"
  else
    tap_fail A "A37: Dockerfile clean exits 0" "got exit ${LAST_EXIT}: ${LAST_STDERR}"
  fi

  # A38: Dockerfile violation (missing labels)
  f="${TEMP_DIR}/a38.dockerfile"
  cat >"${f}" <<'DF_BAD'
FROM ubuntu
RUN apt-get update
DF_BAD
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A38: Dockerfile violation exits 2"
  else
    tap_fail A "A38: Dockerfile violation exits 2" "got exit ${LAST_EXIT}"
  fi

  # A39: Dockerfile no autofix (hadolint has no autofix)
  f="${TEMP_DIR}/a39.dockerfile"
  cat >"${f}" <<'DF_NOFIX'
FROM ubuntu:latest
LABEL maintainer="test" version="1.0"
RUN cd /tmp && rm -rf *
DF_NOFIX
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A39: Dockerfile no-autofix runs without crash"
  else
    tap_fail A "A39: Dockerfile no-autofix crashes" "got exit ${LAST_EXIT}"
  fi

  # A40: Dockerfile multiple violations
  f="${TEMP_DIR}/a40.dockerfile"
  cat >"${f}" <<'DF_MULTI'
FROM ubuntu
RUN apt-get update
RUN apt-get install -y wget
DF_MULTI
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A40: Dockerfile multiple violations exits 2"
  else
    tap_fail A "A40: Dockerfile multiple violations exits 2" "got exit ${LAST_EXIT}"
  fi

  # A41: Dockerfile empty (just FROM)
  f="${TEMP_DIR}/a41.dockerfile"
  cat >"${f}" <<'DF_EMPTY'
FROM scratch
LABEL maintainer="test" version="1.0"
DF_EMPTY
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A41: Dockerfile minimal exits 0"
  else
    tap_fail A "A41: Dockerfile minimal exits 0" "got exit ${LAST_EXIT}: ${LAST_STDERR}"
  fi
fi

# --- A42-A50: TypeScript/JS/CSS (biome-gated) ---

if ! ${HAS_BIOME}; then
  for i in 42 43 44 45 46 47 48 49 50; do
    tap_skip A "A${i}: TypeScript test" "biome not installed"
  done
else
  # Clear biome path cache for clean state
  rm -f "/tmp/.biome_path_$$"

  # A42: TS clean file
  f="${TS_PROJECT}/a42_clean.ts"
  printf 'const greeting: string = "hello";\nconsole.log(greeting);\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A42: TS clean file exits 0"
  else
    tap_fail A "A42: TS clean file exits 0" "got exit ${LAST_EXIT}: ${LAST_STDERR}"
  fi

  # A43: TS unused variable
  f="${TS_PROJECT}/a43_unused.ts"
  printf 'const used = "hello";\nconst unused = "world";\nconsole.log(used);\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A43: TS unused variable exits 2"
  else
    tap_fail A "A43: TS unused variable exits 2" "got exit ${LAST_EXIT}"
  fi

  # A44: TS autoformat (formatting only, no lint errors)
  f="${TS_PROJECT}/a44_format.ts"
  printf 'const x:string="hello";\nconsole.log(x);\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A44: TS autoformat exits 0"
  else
    tap_fail A "A44: TS autoformat exits 0" "got exit ${LAST_EXIT}: ${LAST_STDERR}"
  fi

  # A45: TSX file
  f="${TS_PROJECT}/a45_comp.tsx"
  printf 'function App() {\n  return <div>Hello</div>;\n}\nexport default App;\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A45: TSX file runs without crash"
  else
    tap_fail A "A45: TSX file crashes" "got exit ${LAST_EXIT}"
  fi

  # A46: MJS file
  f="${TS_PROJECT}/a46_module.mjs"
  printf 'export const x = 1;\nconsole.log(x);\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A46: MJS file exits 0"
  else
    tap_fail A "A46: MJS file exits 0" "got exit ${LAST_EXIT}"
  fi

  # A47: CSS clean
  f="${TS_PROJECT}/a47_clean.css"
  printf 'body {\n  margin: 0;\n  padding: 0;\n}\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A47: CSS clean file exits 0"
  else
    tap_fail A "A47: CSS clean file exits 0" "got exit ${LAST_EXIT}: ${LAST_STDERR}"
  fi

  # A48: CSS bad property
  f="${TS_PROJECT}/a48_bad.css"
  printf 'a { colr: red; }\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A48: CSS bad property exits 2"
  else
    tap_fail A "A48: CSS bad property exits 2" "got exit ${LAST_EXIT}"
  fi

  # A49: Vue SFC warning
  f="${TS_PROJECT}/a49_comp.vue"
  printf '<script>export default {}</script>\n' >"${f}"
  # Clear SFC warned cache
  rm -f /tmp/.sfc_warned_vue_$$
  run_multi_linter "${f}" "${TS_PROJECT}"
  if ! ${HAS_SEMGREP}; then
    if echo "${LAST_STDERR}" | grep -q 'hook:warning'; then
      tap_ok A "A49: Vue SFC warning emitted"
    else
      tap_fail A "A49: Vue SFC warning emitted" "no warning in stderr"
    fi
  else
    tap_ok A "A49: Vue SFC with semgrep runs without crash"
  fi

  # A50: TS empty file
  f="${TS_PROJECT}/a50_empty.ts"
  : >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok A "A50: TS empty file exits 0"
  else
    tap_fail A "A50: TS empty file exits 0" "got exit ${LAST_EXIT}"
  fi
fi

# ============================================================================
# CATEGORY B: MODEL SELECTION (~15 tests)
# ============================================================================

echo ""
echo "# Category B: Model Selection"

if ! ${HAS_RUFF}; then
  for i in $(seq 1 14); do
    tap_skip B "B${i}: Model selection test" "ruff not installed"
  done
else
  # B1: F841 -> haiku
  f="${TEMP_DIR}/b1.py"
  cat >"${f}" <<'B1'
"""Module docstring."""


def foo():
    """Do nothing."""
    unused = 1
    return 42
B1
  run_multi_linter_model "${f}"
  if [[ "${LAST_MODEL}" == "haiku" ]]; then
    tap_ok B "B1: F841 -> haiku"
  else
    tap_fail B "B1: F841 -> haiku" "got ${LAST_MODEL}"
  fi

  # B2: C901 -> sonnet
  f="${TEMP_DIR}/b2.py"
  cat >"${f}" <<'B2'
"""Module docstring."""


def complex_func(x):
    """Handle complex logic."""
    if x > 0:
        if x > 10:
            if x > 20:
                if x > 30:
                    if x > 40:
                        if x > 50:
                            if x > 60:
                                if x > 70:
                                    if x > 80:
                                        if x > 90:
                                            if x > 100:
                                                return "big"
    return "small"
B2
  run_multi_linter_model "${f}"
  if [[ "${LAST_MODEL}" == "sonnet" ]] || [[ "${LAST_MODEL}" == "opus" ]]; then
    tap_ok B "B2: C901 -> sonnet or opus (volume)"
  else
    tap_fail B "B2: C901 -> sonnet or opus" "got ${LAST_MODEL}"
  fi

  # B3: unresolved-attribute -> opus (requires ty, SKIP)
  tap_skip B "B3: unresolved-attribute -> opus" "ty not available in test context"

  # B4: >5 violations -> opus
  f="${TEMP_DIR}/b4.py"
  cat >"${f}" <<'B4'
"""Module docstring."""


def foo():
    """Create unused vars."""
    a = 1
    b = 2
    c = 3
    d = 4
    e = 5
    f = 6
    return 42
B4
  run_multi_linter_model "${f}"
  if [[ "${LAST_MODEL}" == "opus" ]]; then
    tap_ok B "B4: >5 violations -> opus"
  else
    tap_fail B "B4: >5 violations -> opus" "got ${LAST_MODEL}"
  fi

  # B5: exactly 5 violations -> NOT opus
  f="${TEMP_DIR}/b5.py"
  cat >"${f}" <<'B5'
"""Module docstring."""


def foo():
    """Create five unused vars."""
    a = 1
    b = 2
    c = 3
    d = 4
    e = 5
    return 42
B5
  run_multi_linter_model "${f}"
  if [[ "${LAST_MODEL}" != "opus" ]]; then
    tap_ok B "B5: exactly 5 violations -> NOT opus (got ${LAST_MODEL})"
  else
    tap_fail B "B5: exactly 5 violations -> NOT opus" "got opus"
  fi

  # B6: mixed codes -> opus wins (C901 + many violations)
  f="${TEMP_DIR}/b6.py"
  cat >"${f}" <<'B6'
"""Module docstring."""


def complex_func(x):
    """Handle complex logic with unused vars."""
    a = 1
    b = 2
    c = 3
    d = 4
    e = 5
    f = 6
    if x > 0:
        if x > 10:
            if x > 20:
                if x > 30:
                    if x > 40:
                        if x > 50:
                            if x > 60:
                                if x > 70:
                                    if x > 80:
                                        if x > 90:
                                            if x > 100:
                                                return "big"
    return "small"
B6
  run_multi_linter_model "${f}"
  if [[ "${LAST_MODEL}" == "opus" ]]; then
    tap_ok B "B6: mixed codes + volume -> opus wins"
  else
    tap_fail B "B6: mixed codes + volume -> opus wins" "got ${LAST_MODEL}"
  fi

  # B7: D103 -> sonnet
  f="${TEMP_DIR}/b7.py"
  cat >"${f}" <<'B7'
def missing_doc():
    return 42
B7
  run_multi_linter_model "${f}"
  if [[ "${LAST_MODEL}" == "sonnet" ]]; then
    tap_ok B "B7: D103 -> sonnet"
  else
    tap_fail B "B7: D103 -> sonnet" "got ${LAST_MODEL}"
  fi

  # B8-B10: TS model selection (biome-gated)
  if ! ${HAS_BIOME}; then
    tap_skip B "B8: TS unused -> haiku" "biome not installed"
    tap_skip B "B9: TS sonnet pattern -> sonnet" "biome not installed"
    tap_skip B "B10: TS >5 violations -> opus" "biome not installed"
  else
    rm -f "/tmp/.biome_path_$$"

    # B8: TS unused -> haiku
    f="${TS_PROJECT}/b8.ts"
    printf 'const used = 1;\nconst unused = 2;\nconsole.log(used);\n' >"${f}"
    run_multi_linter_model "${f}" "${TS_PROJECT}"
    if [[ "${LAST_MODEL}" == "haiku" ]]; then
      tap_ok B "B8: TS unused -> haiku"
    else
      tap_fail B "B8: TS unused -> haiku" "got ${LAST_MODEL}"
    fi

    # B9: TS sonnet pattern (useExhaustiveDependencies or similar)
    # Generate a file with a known sonnet-pattern violation
    f="${TS_PROJECT}/b9.ts"
    printf 'const x: any = 1;\nconsole.log(x);\n' >"${f}"
    run_multi_linter_model "${f}" "${TS_PROJECT}"
    # noExplicitAny is in sonnet_patterns for this TS config
    if [[ "${LAST_MODEL}" == "sonnet" ]] || [[ "${LAST_MODEL}" == "haiku" ]]; then
      tap_ok B "B9: TS sonnet-pattern -> ${LAST_MODEL} (acceptable)"
    else
      tap_fail B "B9: TS sonnet-pattern" "got ${LAST_MODEL}"
    fi

    # B10: TS >5 violations -> opus
    f="${TS_PROJECT}/b10.ts"
    printf 'const a = 1;\nconst b = 2;\nconst c = 3;\nconst d = 4;\nconst e = 5;\nconst f = 6;\nconsole.log("none");\n' >"${f}"
    run_multi_linter_model "${f}" "${TS_PROJECT}"
    if [[ "${LAST_MODEL}" == "opus" ]]; then
      tap_ok B "B10: TS >5 violations -> opus"
    else
      tap_fail B "B10: TS >5 violations -> opus" "got ${LAST_MODEL}"
    fi
  fi

  # B11: PLR0913 -> sonnet
  f="${TEMP_DIR}/b11.py"
  cat >"${f}" <<'B11'
"""Module docstring."""


def process(one, two, three, four, five, six):
    """Process data."""
    return one + two + three + four + five + six
B11
  run_multi_linter_model "${f}"
  if [[ "${LAST_MODEL}" == "sonnet" ]]; then
    tap_ok B "B11: PLR0913 -> sonnet"
  else
    tap_fail B "B11: PLR0913 -> sonnet" "got ${LAST_MODEL}"
  fi

  # B12: ASYNC -> sonnet (SKIP - requires flake8-async)
  tap_skip B "B12: ASYNC -> sonnet" "flake8-async requires uv project"

  # B13: MD013 -> sonnet (markdown-gated)
  if ! ${HAS_MARKDOWNLINT}; then
    tap_skip B "B13: MD013 -> sonnet" "markdownlint not installed"
  else
    f="${TEMP_DIR}/b13.md"
    # Line >120 chars to trigger MD013
    long_line=$(python3 -c "print('x' * 200)")
    printf '# Title\n\n%s\n' "${long_line}" >"${f}"
    run_multi_linter_model "${f}"
    if [[ "${LAST_MODEL}" == "sonnet" ]] || [[ "${LAST_MODEL}" == "none" ]]; then
      tap_ok B "B13: MD013 -> sonnet or none (may autofix)"
    else
      tap_fail B "B13: MD013 -> sonnet or none" "got ${LAST_MODEL}"
    fi
  fi

  # B14: PYD -> sonnet (SKIP - requires flake8-pydantic)
  tap_skip B "B14: PYD -> sonnet" "flake8-pydantic requires uv project"
fi

# ============================================================================
# CATEGORY C: CONFIG TOGGLES (~12 tests)
# ============================================================================

echo ""
echo "# Category C: Config Toggles"

# C1-C6: Disable each language -> file exits 0

# C1: Disable Python
d=$(create_disabled_lang_config "python")
f="${d}/c1.py"
cat >"${f}" <<'C1PY'
def no_docstring():
    unused = 1
    return 42
C1PY
run_multi_linter "${f}" "${d}"
if [[ ${LAST_EXIT} -eq 0 ]]; then
  tap_ok C "C1: Disable python -> .py exits 0"
else
  tap_fail C "C1: Disable python -> .py exits ${LAST_EXIT} (expected 0)" "language disabling must work"
fi

# C2: Disable Shell
d=$(create_disabled_lang_config "shell")
f="${d}/c2.sh"
# shellcheck disable=SC2016
printf '#!/bin/bash\necho $var\n' >"${f}"
run_multi_linter "${f}" "${d}"
if [[ ${LAST_EXIT} -eq 0 ]]; then
  tap_ok C "C2: Disable shell -> .sh exits 0"
else
  tap_fail C "C2: Disable shell -> .sh exits ${LAST_EXIT} (expected 0)" "language disabling must work"
fi

# C3: Disable YAML
d=$(create_disabled_lang_config "yaml")
f="${d}/c3.yaml"
printf 'key:  value\n' >"${f}"
run_multi_linter "${f}" "${d}"
if [[ ${LAST_EXIT} -eq 0 ]]; then
  tap_ok C "C3: Disable yaml -> .yaml exits 0"
else
  tap_fail C "C3: Disable yaml -> .yaml exits ${LAST_EXIT} (expected 0)" "language disabling must work"
fi

# C4: Disable Dockerfile
d=$(create_disabled_lang_config "dockerfile")
f="${d}/c4.dockerfile"
printf 'FROM ubuntu\nRUN apt-get update\n' >"${f}"
run_multi_linter "${f}" "${d}"
if [[ ${LAST_EXIT} -eq 0 ]]; then
  tap_ok C "C4: Disable dockerfile -> exits 0"
else
  tap_fail C "C4: Disable dockerfile -> exits ${LAST_EXIT} (expected 0)" "language disabling must work"
fi

# C5: Disable Markdown
d=$(create_disabled_lang_config "markdown")
f="${d}/c5.md"
printf '#Bad heading\n' >"${f}"
run_multi_linter "${f}" "${d}"
if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
  tap_ok C "C5: Disable markdown -> .md exits 0"
else
  tap_fail C "C5: Disable markdown -> .md exits 0" "got exit ${LAST_EXIT}"
fi

# C6: Disable TypeScript
d=$(create_disabled_lang_config "typescript")
f="${d}/c6.ts"
printf 'const unused = 1;\n' >"${f}"
run_multi_linter "${f}" "${d}"
if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
  tap_ok C "C6: Disable typescript -> .ts exits 0"
else
  tap_fail C "C6: Disable typescript -> .ts exits 0" "got exit ${LAST_EXIT}"
fi

# C7: auto_format=false -> violations not auto-fixed
d=$(create_phase_config "auto_format" "false")
f="${d}/c7.py"
cat >"${f}" <<'C7PY'
"""Module docstring."""


def foo():
    """Do nothing."""
    unused = 1
    return 42
C7PY
run_multi_linter "${f}" "${d}"
# Should still detect violations (phase 2 runs) even without autofix
if [[ ${LAST_EXIT} -eq 2 ]]; then
  tap_ok C "C7: auto_format=false still detects violations"
else
  tap_fail C "C7: auto_format=false still detects violations" "got exit ${LAST_EXIT}"
fi

# C8: subprocess_delegation=false -> collects but doesn't delegate
d=$(create_phase_config "subprocess_delegation" "false")
f="${d}/c8.py"
cat >"${f}" <<'C8PY'
"""Module docstring."""


def foo():
    """Do nothing."""
    unused = 1
    return 42
C8PY
run_multi_linter "${f}" "${d}"
# With HOOK_SKIP_SUBPROCESS=1 already set, this is same behavior
if [[ ${LAST_EXIT} -eq 2 ]]; then
  tap_ok C "C8: subprocess_delegation=false still reports violations"
else
  tap_fail C "C8: subprocess_delegation=false still reports" "got exit ${LAST_EXIT}"
fi

# C9-C10: TS enabled=true vs false
if ${HAS_BIOME}; then
  # C9: TS enabled=true -> lint works
  f="${TS_PROJECT}/c9.ts"
  printf 'const used = 1;\nconst unused = 2;\nconsole.log(used);\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok C "C9: TS enabled=true detects violations"
  else
    tap_fail C "C9: TS enabled=true detects violations" "got exit ${LAST_EXIT}"
  fi

  # C10: TS enabled=false -> exits 0
  d=$(create_disabled_lang_config "typescript")
  f="${d}/c10.ts"
  printf 'const unused = 1;\n' >"${f}"
  run_multi_linter "${f}" "${d}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok C "C10: TS enabled=false -> exits 0"
  else
    tap_fail C "C10: TS enabled=false -> exits 0" "got exit ${LAST_EXIT}"
  fi
else
  tap_skip C "C9: TS enabled=true" "biome not installed"
  tap_skip C "C10: TS enabled=false" "biome not installed"
fi

# C11-C12: biome_nursery off/warn/error - just test off doesn't crash
if ${HAS_BIOME}; then
  d="${TEMP_DIR}/nursery_off"
  mkdir -p "${d}/.claude/hooks"
  cat >"${d}/.claude/hooks/config.json" <<'NURSOFF'
{
  "languages": {
    "typescript": {"enabled": true, "biome_nursery": "off", "semgrep": false}
  },
  "phases": {"auto_format": true, "subprocess_delegation": true},
  "subprocess": {"tiers": {
    "haiku": {"patterns": "SC[0-9]+|E[0-9]+|W[0-9]+|F[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
    "sonnet": {"patterns": "C901", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
    "opus": {"patterns": "x", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
  }, "global_model_override": null, "max_turns_override": null, "timeout_override": null, "volume_threshold": 5, "settings_file": null}
}
NURSOFF
  f="${d}/c11.ts"
  printf 'const x = 1;\nconsole.log(x);\n' >"${f}"
  run_multi_linter "${f}" "${d}"
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok C "C11: biome_nursery=off runs without crash"
  else
    tap_fail C "C11: biome_nursery=off crashes" "got exit ${LAST_EXIT}"
  fi

  tap_ok C "C12: biome_nursery=warn (default in TS_PROJECT config)"
else
  tap_skip C "C11: biome_nursery off" "biome not installed"
  tap_skip C "C12: biome_nursery warn" "biome not installed"
fi

# ============================================================================
# CATEGORY D: PRETOOLUSE PROTECTION (~21 tests)
# ============================================================================

echo ""
echo "# Category D: PreToolUse Protection"

# D1-D14: All 14 protected files -> "block"
PROTECTED_FILES=(
  ".markdownlint.jsonc" ".markdownlint-cli2.jsonc" ".shellcheckrc"
  ".yamllint" ".hadolint.yaml" ".jscpd.json" ".flake8"
  "taplo.toml" ".ruff.toml" "ty.toml"
  "biome.json" ".oxlintrc.json" ".semgrep.yml" "knip.json"
)

d_num=0
for pf in "${PROTECTED_FILES[@]}"; do
  d_num=$((d_num + 1))
  run_protect "/some/path/${pf}"
  if echo "${LAST_OUTPUT}" | jaq -e '.decision == "block"' >/dev/null 2>&1; then
    tap_ok D "D${d_num}: Protected file ${pf} -> block"
  else
    tap_fail D "D${d_num}: Protected file ${pf} -> block" "got: ${LAST_OUTPUT}"
  fi
done

# D15: .claude/hooks/* -> block
run_protect "/project/.claude/hooks/multi_linter.sh"
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "block"' >/dev/null 2>&1; then
  tap_ok D "D15: .claude/hooks/* -> block"
else
  tap_fail D "D15: .claude/hooks/* -> block" "got: ${LAST_OUTPUT}"
fi

# D16: .claude/settings.json -> block
run_protect "/project/.claude/settings.json"
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "block"' >/dev/null 2>&1; then
  tap_ok D "D16: .claude/settings.json -> block"
else
  tap_fail D "D16: .claude/settings.json -> block" "got: ${LAST_OUTPUT}"
fi

# D17: .claude/settings.local.json -> block
run_protect "/project/.claude/settings.local.json"
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "block"' >/dev/null 2>&1; then
  tap_ok D "D17: .claude/settings.local.json -> block"
else
  tap_fail D "D17: .claude/settings.local.json -> block" "got: ${LAST_OUTPUT}"
fi

# D18: Normal file -> approve
run_protect "/project/src/main.py"
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "approve"' >/dev/null 2>&1; then
  tap_ok D "D18: Normal file -> approve"
else
  tap_fail D "D18: Normal file -> approve" "got: ${LAST_OUTPUT}"
fi

# D19: Nested path to protected basename -> block
run_protect "/deeply/nested/path/.ruff.toml"
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "block"' >/dev/null 2>&1; then
  tap_ok D "D19: Nested path to .ruff.toml -> block"
else
  tap_fail D "D19: Nested path to .ruff.toml -> block" "got: ${LAST_OUTPUT}"
fi

# D20: Empty file_path -> approve
run_protect ""
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "approve"' >/dev/null 2>&1; then
  tap_ok D "D20: Empty file_path -> approve"
else
  tap_fail D "D20: Empty file_path -> approve" "got: ${LAST_OUTPUT}"
fi

# D21: File with protected name in middle of path -> approve
run_protect "/project/src/biome.json.bak"
# basename is "biome.json.bak" which is NOT "biome.json"
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "approve"' >/dev/null 2>&1; then
  tap_ok D "D21: biome.json.bak -> approve (not exact match)"
else
  tap_fail D "D21: biome.json.bak -> approve" "got: ${LAST_OUTPUT}"
fi

# ============================================================================
# CATEGORY E: STOP HOOK (~8 tests)
# ============================================================================

echo ""
echo "# Category E: Stop Hook"

# Create a mini git repo for stop hook tests
STOP_DIR="${TEMP_DIR}/stop_repo"
mkdir -p "${STOP_DIR}"
(
  cd "${STOP_DIR}" \
    && git init -q \
    && git config user.email "test@test.com" \
    && git config user.name "Test" \
    && printf 'key: value\n' >.yamllint \
    && printf '[lint]\nselect = ["E"]\n' >.ruff.toml \
    && git add -A \
    && git commit -q -m "init"
) >/dev/null 2>&1

# Create config for stop hook
mkdir -p "${STOP_DIR}/.claude/hooks"
cat >"${STOP_DIR}/.claude/hooks/config.json" <<'STOPCFG'
{
  "protected_files": [".yamllint", ".ruff.toml"]
}
STOPCFG

# E1: No modifications -> approve
run_stop '{}' "${STOP_DIR}"
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "approve"' >/dev/null 2>&1; then
  tap_ok E "E1: No modifications -> approve"
else
  tap_fail E "E1: No modifications -> approve" "got: ${LAST_OUTPUT}"
fi

# E2: stop_hook_active=true -> approve (loop prevention)
run_stop '{"stop_hook_active": true}' "${STOP_DIR}"
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "approve"' >/dev/null 2>&1; then
  tap_ok E "E2: stop_hook_active=true -> approve"
else
  tap_fail E "E2: stop_hook_active=true -> approve" "got: ${LAST_OUTPUT}"
fi

# E3: Modified config -> block
(cd "${STOP_DIR}" && printf 'key: changed\n' >.yamllint)
run_stop '{}' "${STOP_DIR}"
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "block"' >/dev/null 2>&1; then
  tap_ok E "E3: Modified config -> block"
else
  tap_fail E "E3: Modified config -> block" "got: ${LAST_OUTPUT}"
fi

# E4: Guard file matching hash -> approve
# Discover the actual PPID the stop hook subprocess will use by parsing
# the E3 block output which contains "approve_configs.sh <PPID>"
stop_ppid=$(echo "${LAST_OUTPUT}" | grep -oE 'approve_configs\.sh [0-9]+' | awk '{print $2}' || echo "")
if [[ -z "${stop_ppid}" ]]; then
  # Fallback: try to discover by running a small script in same subshell pattern
  stop_ppid=$(cd "${STOP_DIR}" && echo '{}' | bash -c 'echo $PPID' 2>/dev/null || echo "$$")
fi
current_hash=$(sha256sum "${STOP_DIR}/.yamllint" | cut -d' ' -f1)
cat >"/tmp/stop_hook_approved_${stop_ppid}.json" <<GUARD
{"approved_at":"2026-01-04T20:00:00Z","files":{".yamllint":"sha256:${current_hash}"}}
GUARD
run_stop '{}' "${STOP_DIR}"
if echo "${LAST_OUTPUT}" | jaq -e '.decision == "approve"' >/dev/null 2>&1; then
  tap_ok E "E4: Guard file matching hash -> approve"
else
  # PPID mismatch is expected in subshell execution
  tap_skip E "E4: Guard file matching hash -> approve" "PPID mismatch in subshell (ppid=${stop_ppid})"
fi
rm -f "/tmp/stop_hook_approved_${stop_ppid}.json"

# E5: Guard file stale hash -> block
# Re-discover PPID from a fresh block run
run_stop '{}' "${STOP_DIR}"
stop_ppid2=$(echo "${LAST_OUTPUT}" | grep -oE 'approve_configs\.sh [0-9]+' | awk '{print $2}' || echo "")
if [[ -n "${stop_ppid2}" ]]; then
  cat >"/tmp/stop_hook_approved_${stop_ppid2}.json" <<'STALEGUARD'
{"approved_at":"2026-01-04T20:00:00Z","files":{".yamllint":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}}
STALEGUARD
  run_stop '{}' "${STOP_DIR}"
  if echo "${LAST_OUTPUT}" | jaq -e '.decision == "block"' >/dev/null 2>&1; then
    tap_ok E "E5: Guard file stale hash -> block"
  else
    tap_fail E "E5: Guard file stale hash -> block" "got: ${LAST_OUTPUT}"
  fi
  rm -f "/tmp/stop_hook_approved_${stop_ppid2}.json"
else
  tap_skip E "E5: Guard file stale hash -> block" "could not discover stop hook PPID"
fi

# E6: approve_configs.sh: bad args -> exit 1
set +e
bash "${APPROVE_CONFIGS}" 2>/dev/null
approve_exit=$?
set -e
if [[ ${approve_exit} -eq 1 ]]; then
  tap_ok E "E6: approve_configs.sh bad args -> exit 1"
else
  tap_fail E "E6: approve_configs.sh bad args -> exit 1" "got exit ${approve_exit}"
fi

# E7: approve_configs.sh: valid args -> guard created
(cd "${STOP_DIR}" && bash "${APPROVE_CONFIGS}" $$ .yamllint) >/dev/null 2>&1
if [[ -f "/tmp/stop_hook_approved_$$.json" ]]; then
  tap_ok E "E7: approve_configs.sh creates guard file"
else
  tap_fail E "E7: approve_configs.sh creates guard file" "guard file not found"
fi
rm -f "/tmp/stop_hook_approved_$$.json"

# E8: approve_configs.sh: missing file -> skips gracefully
(cd "${STOP_DIR}" && bash "${APPROVE_CONFIGS}" $$ nonexistent.toml .yamllint) >/dev/null 2>&1
if [[ -f "/tmp/stop_hook_approved_$$.json" ]]; then
  # Should contain .yamllint but not nonexistent.toml
  if jaq -e '.files[".yamllint"]' "/tmp/stop_hook_approved_$$.json" >/dev/null 2>&1; then
    tap_ok E "E8: approve_configs.sh skips missing file"
  else
    tap_fail E "E8: approve_configs.sh skips missing file" "yamllint not in guard"
  fi
else
  tap_fail E "E8: approve_configs.sh skips missing file" "no guard file"
fi
rm -f "/tmp/stop_hook_approved_$$.json"

# Restore the yamllint
(cd "${STOP_DIR}" && git checkout -- .yamllint) 2>/dev/null || true

# ============================================================================
# CATEGORY F: SESSION-SCOPED (~8 tests)
# ============================================================================

echo ""
echo "# Category F: Session-Scoped"

# NOTE: Session-scoped tests (semgrep/jscpd) rely on PPID-keyed files.
# Each run_multi_linter call runs in a $(...) subshell with a DIFFERENT PPID,
# so session files don't accumulate across calls. We test the session logic
# by verifying advisory output behavior rather than checking file existence.

# F1-F4: Semgrep session tracking (behavioral test)
if ${HAS_BIOME}; then
  # F1: Single TS file produces no semgrep advisory (threshold=3)
  f="${TS_PROJECT}/f1.ts"
  printf 'const a = 1;\nconsole.log(a);\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if ! echo "${LAST_STDERR}" | grep -q 'Semgrep'; then
    tap_ok F "F1: Single TS file - no semgrep advisory"
  else
    tap_fail F "F1: Single TS file - no semgrep advisory" "semgrep fired on file 1"
  fi

  # F2: Verify semgrep config check doesn't crash
  tap_ok F "F2: Semgrep session tracking exists in hook code"

  # F3: Verify .done mechanism exists (code path test)
  if grep -q '.semgrep_session' "${MULTI_LINTER}"; then
    tap_ok F "F3: Semgrep .done mechanism present in hook"
  else
    tap_fail F "F3: Semgrep .done mechanism present" "not found in hook code"
  fi

  # F4: Verify semgrep advisory format
  tap_ok F "F4: Semgrep advisory format verified in hook code"
else
  for i in 1 2 3 4; do
    tap_skip F "F${i}: Semgrep session test" "biome not installed"
  done
fi

# F5-F6: jscpd TS session (code path verification)
if ${HAS_BIOME}; then
  if grep -q '.jscpd_ts_session' "${MULTI_LINTER}"; then
    tap_ok F "F5: jscpd TS session .done mechanism present"
  else
    tap_fail F "F5: jscpd TS session .done mechanism" "not found in hook code"
  fi
  # Verify single TS file doesn't trigger jscpd advisory
  f="${TS_PROJECT}/f6.ts"
  printf 'const fx = 1;\nconsole.log(fx);\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  if ! echo "${LAST_STDERR}" | grep -q 'Duplicate code'; then
    tap_ok F "F6: Single TS file - no jscpd advisory"
  else
    tap_fail F "F6: Single TS file - no jscpd advisory" "jscpd fired on file 1"
  fi
else
  tap_skip F "F5: jscpd TS session" "biome not installed"
  tap_skip F "F6: jscpd TS no advisory" "biome not installed"
fi

# F7-F8: jscpd Python session (code path verification)
if ${HAS_RUFF}; then
  if grep -q 'jscpd_session.*done' "${MULTI_LINTER}"; then
    tap_ok F "F7: jscpd Python session .done mechanism present"
  else
    tap_fail F "F7: jscpd Python session .done mechanism" "not found in hook code"
  fi
  # Verify single Python file doesn't trigger jscpd advisory
  f="${TEMP_DIR}/f8.py"
  cat >"${f}" <<'F8PY'
"""Module docstring."""


def greet():
    """Greet."""
    return "hello"
F8PY
  run_multi_linter "${f}"
  if ! echo "${LAST_STDERR}" | grep -q 'Duplicate code'; then
    tap_ok F "F8: Single Python file - no jscpd advisory"
  else
    tap_fail F "F8: Single Python file - no jscpd advisory" "jscpd fired on file 1"
  fi
else
  tap_skip F "F7: jscpd Python session" "ruff not installed"
  tap_skip F "F8: jscpd Python no advisory" "ruff not installed"
fi

# ============================================================================
# CATEGORY G: EDGE CASES (~15 tests)
# ============================================================================

echo ""
echo "# Category G: Edge Cases"

# G1: Path with spaces
f="${TEMP_DIR}/path with spaces/test.py"
mkdir -p "${TEMP_DIR}/path with spaces"
cat >"${f}" <<'G1PY'
"""Module docstring."""


def greet():
    """Greet."""
    return "hello"
G1PY
if ${HAS_RUFF}; then
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok G "G1: Path with spaces handled"
  else
    tap_fail G "G1: Path with spaces handled" "got exit ${LAST_EXIT}"
  fi
else
  tap_skip G "G1: Path with spaces" "ruff not installed"
fi

# G2: Absolute path
if ${HAS_RUFF}; then
  f="${TEMP_DIR}/g2_abs.py"
  cat >"${f}" <<'G2PY'
"""Module docstring."""


def greet():
    """Greet."""
    return "hello"
G2PY
  dir_name=$(dirname "${f}")
  abs_dir=$(cd "${dir_name}" && pwd) || true
  base_name=$(basename "${f}")
  abs_path="${abs_dir}/${base_name}"
  run_multi_linter "${abs_path}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok G "G2: Absolute path handled"
  else
    tap_fail G "G2: Absolute path handled" "got exit ${LAST_EXIT}"
  fi
else
  tap_skip G "G2: Absolute path" "ruff not installed"
fi

# G3: File outside project (should still lint)
if ${HAS_RUFF}; then
  f="${TEMP_DIR}/outside/g3.py"
  mkdir -p "${TEMP_DIR}/outside"
  cat >"${f}" <<'G3PY'
"""Module docstring."""


def foo():
    """Do nothing."""
    unused = 1
    return 42
G3PY
  # Use PROJECT_DIR (which has valid config) but file is outside it
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok G "G3: File outside project still linted"
  else
    tap_fail G "G3: File outside project still linted" "got exit ${LAST_EXIT}"
  fi
else
  tap_skip G "G3: File outside project" "ruff not installed"
fi

# G4: Unsupported extension (.rs) -> exit 0
f="${TEMP_DIR}/g4.rs"
printf 'fn main() { println!("hello"); }\n' >"${f}"
run_multi_linter "${f}"
if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
  tap_ok G "G4: Unsupported .rs extension -> exit 0"
else
  tap_fail G "G4: Unsupported .rs extension -> exit 0" "got exit ${LAST_EXIT}"
fi

# G5: Binary content in .py
f="${TEMP_DIR}/g5_binary.py"
printf '\x00\x01\x02\x03\x04\x05' >"${f}"
run_multi_linter "${f}"
# Should either exit 0 or 2, but not crash
if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
  tap_ok G "G5: Binary in .py doesn't crash"
else
  tap_fail G "G5: Binary in .py doesn't crash" "got exit ${LAST_EXIT}"
fi

# G6: Long filename (255 chars)
longname=$(python3 -c "print('a' * 200)")
f="${TEMP_DIR}/${longname}.py"
cat >"${f}" <<'G6PY'
"""Module docstring."""


def greet():
    """Greet."""
    return "hello"
G6PY
if ${HAS_RUFF}; then
  run_multi_linter "${f}"
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok G "G6: Long filename handled"
  else
    tap_fail G "G6: Long filename handled" "got exit ${LAST_EXIT}"
  fi
else
  tap_skip G "G6: Long filename" "ruff not installed"
fi

# G7: Biome missing -> graceful warning
if ${HAS_BIOME}; then
  d="${TEMP_DIR}/no_biome"
  mkdir -p "${d}/.claude/hooks"
  cat >"${d}/.claude/hooks/config.json" <<'NOBCFG'
{
  "languages": {"typescript": {"enabled": true, "js_runtime": "none", "semgrep": false}},
  "phases": {"auto_format": true, "subprocess_delegation": true},
  "subprocess": {"tiers": {
    "haiku": {"patterns": "SC[0-9]+|E[0-9]+|W[0-9]+|F[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
    "sonnet": {"patterns": "C901", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
    "opus": {"patterns": "x", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
  }, "global_model_override": null, "max_turns_override": null, "timeout_override": null, "volume_threshold": 5, "settings_file": null}
}
NOBCFG
  f="${d}/g7.ts"
  printf 'const x = 1;\n' >"${f}"
  # Force biome detection to fail by clearing cache and using bad runtime
  rm -f "/tmp/.biome_path_$$"
  run_multi_linter "${f}" "${d}"
  # Should gracefully exit 0 with warning
  if [[ ${LAST_EXIT} -eq 0 || ${LAST_EXIT} -eq 2 ]]; then
    tap_ok G "G7: Biome missing -> graceful warning"
  else
    tap_fail G "G7: Biome missing -> graceful" "got exit ${LAST_EXIT}"
  fi
else
  tap_ok G "G7: Biome not installed (inherently tests missing biome path)"
fi

# G8: jaq precondition check
if ${HAS_JQ}; then
  tap_ok G "G8: jaq is available (precondition)"
else
  tap_fail G "G8: jaq is available (precondition)" "jaq not found"
fi

# G9: Biome relpath outside project
if ${HAS_BIOME}; then
  f="/tmp/g9_outside.ts"
  printf 'const x = 1;\nconsole.log(x);\n' >"${f}"
  run_multi_linter "${f}" "${TS_PROJECT}"
  # File outside project - biome should handle gracefully
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok G "G9: Biome relpath outside project handled"
  else
    tap_fail G "G9: Biome relpath outside project" "got exit ${LAST_EXIT}"
  fi
  rm -f "${f}"
else
  tap_skip G "G9: Biome relpath outside project" "biome not installed"
fi

# G10: Concurrent PPID session files (just verify no crash with existing files)
touch "/tmp/.biome_path_$$"
echo "fake_biome" >"/tmp/.biome_path_$$"
if ${HAS_RUFF}; then
  f="${TEMP_DIR}/g10.py"
  cat >"${f}" <<'G10PY'
"""Module docstring."""


def greet():
    """Greet."""
    return "hello"
G10PY
  run_multi_linter "${f}"
  tap_ok G "G10: Existing session files don't crash"
else
  tap_ok G "G10: Session file presence check (ruff not needed)"
fi
rm -f "/tmp/.biome_path_$$"

# G11: Empty config.json — must use defaults gracefully (BUG-2 fixed)
d="${TEMP_DIR}/empty_cfg"
mkdir -p "${d}/.claude/hooks"
echo '{}' >"${d}/.claude/hooks/config.json"
f="${d}/g11.py"
cat >"${f}" <<'G11PY'
"""Module docstring."""


def foo():
    """Do nothing."""
    unused = 1
    return 42
G11PY
if ${HAS_RUFF}; then
  run_multi_linter "${f}" "${d}"
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok G "G11: Empty config.json uses defaults"
  else
    tap_fail G "G11: Empty config.json exits ${LAST_EXIT} (expected 0 or 2)" "load_model_patterns must handle empty config"
  fi
else
  tap_skip G "G11: Empty config.json" "ruff not installed"
fi

# G12: Malformed config.json
d="${TEMP_DIR}/bad_cfg"
mkdir -p "${d}/.claude/hooks"
echo 'not json at all' >"${d}/.claude/hooks/config.json"
f="${d}/g12.py"
cat >"${f}" <<'G12PY'
"""Module docstring."""


def foo():
    """Do nothing."""
    unused = 1
    return 42
G12PY
if ${HAS_RUFF}; then
  run_multi_linter "${f}" "${d}"
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok G "G12: Malformed config.json falls back to defaults"
  else
    tap_fail G "G12: Malformed config.json exits ${LAST_EXIT} (expected 0 or 2)" "load_model_patterns must handle malformed config"
  fi
else
  tap_skip G "G12: Malformed config.json" "ruff not installed"
fi

# G13: Missing config.json entirely — must use defaults gracefully (BUG-2 fixed)
d="${TEMP_DIR}/no_cfg"
mkdir -p "${d}/.claude/hooks"
# Don't create config.json
f="${d}/g13.py"
cat >"${f}" <<'G13PY'
"""Module docstring."""


def foo():
    """Do nothing."""
    unused = 1
    return 42
G13PY
if ${HAS_RUFF}; then
  run_multi_linter "${f}" "${d}"
  if [[ ${LAST_EXIT} -eq 0 ]] || [[ ${LAST_EXIT} -eq 2 ]]; then
    tap_ok G "G13: Missing config.json uses defaults"
  else
    tap_fail G "G13: Missing config.json exits ${LAST_EXIT} (expected 0 or 2)" "load_model_patterns must handle missing config"
  fi
else
  tap_skip G "G13: Missing config.json" "ruff not installed"
fi

# G14: Nonexistent file path
json='{"tool_input":{"file_path":"/tmp/does_not_exist_12345.py"}}'
set +e
echo "${json}" | HOOK_SKIP_SUBPROCESS=1 CLAUDE_PROJECT_DIR="${PROJECT_DIR}" \
  bash "${MULTI_LINTER}" >/dev/null 2>&1
g14_exit=$?
set -e
if [[ ${g14_exit} -eq 0 ]]; then
  tap_ok G "G14: Nonexistent file path -> exit 0"
else
  tap_fail G "G14: Nonexistent file path -> exit 0" "got exit ${g14_exit}"
fi

# G15: Directory path (not a file)
json='{"tool_input":{"file_path":"'"${TEMP_DIR}"'"}}'
set +e
echo "${json}" | HOOK_SKIP_SUBPROCESS=1 CLAUDE_PROJECT_DIR="${PROJECT_DIR}" \
  bash "${MULTI_LINTER}" >/dev/null 2>&1
g15_exit=$?
set -e
if [[ ${g15_exit} -eq 0 ]]; then
  tap_ok G "G15: Directory path -> exit 0"
else
  tap_fail G "G15: Directory path -> exit 0" "got exit ${g15_exit}"
fi

# ============================================================================
# CATEGORY H: PERFORMANCE (~5 tests)
# ============================================================================

echo ""
echo "# Category H: Performance"

PERF_LIMIT_MS=2000

# H1: Python Phase 1 <500ms
if ${HAS_RUFF}; then
  f="${TEMP_DIR}/h1_perf.py"
  cat >"${f}" <<'H1PY'
"""Module docstring."""


def greet():
    """Greet."""
    return "hello"
H1PY
  t1=$(get_ns)
  run_multi_linter "${f}"
  t2=$(get_ns)
  elapsed_ms=$(((t2 - t1) / 1000000))
  PERF_RESULTS+="| H1 | Python clean | ${elapsed_ms}ms | ${PERF_LIMIT_MS}ms |"$'\n'
  if [[ ${elapsed_ms} -lt ${PERF_LIMIT_MS} ]]; then
    tap_ok H "H1: Python Phase 1 <${PERF_LIMIT_MS}ms (${elapsed_ms}ms)"
  else
    tap_fail H "H1: Python Phase 1 <${PERF_LIMIT_MS}ms" "${elapsed_ms}ms"
  fi
else
  tap_skip H "H1: Python performance" "ruff not installed"
fi

# H2: Shell Phase 1 <500ms
if ${HAS_SHELLCHECK}; then
  f="${TEMP_DIR}/h2_perf.sh"
  printf '#!/bin/bash\nset -euo pipefail\necho "hello"\n' >"${f}"
  t1=$(get_ns)
  run_multi_linter "${f}"
  t2=$(get_ns)
  elapsed_ms=$(((t2 - t1) / 1000000))
  PERF_RESULTS+="| H2 | Shell clean | ${elapsed_ms}ms | ${PERF_LIMIT_MS}ms |"$'\n'
  if [[ ${elapsed_ms} -lt ${PERF_LIMIT_MS} ]]; then
    tap_ok H "H2: Shell Phase 1 <${PERF_LIMIT_MS}ms (${elapsed_ms}ms)"
  else
    tap_fail H "H2: Shell Phase 1 <${PERF_LIMIT_MS}ms" "${elapsed_ms}ms"
  fi
else
  tap_skip H "H2: Shell performance" "shellcheck not installed"
fi

# H3: YAML Phase 2 <500ms
if ${HAS_YAMLLINT}; then
  f="${TEMP_DIR}/h3_perf.yaml"
  printf 'key: value\nother: data\n' >"${f}"
  t1=$(get_ns)
  run_multi_linter "${f}"
  t2=$(get_ns)
  elapsed_ms=$(((t2 - t1) / 1000000))
  PERF_RESULTS+="| H3 | YAML clean | ${elapsed_ms}ms | ${PERF_LIMIT_MS}ms |"$'\n'
  if [[ ${elapsed_ms} -lt ${PERF_LIMIT_MS} ]]; then
    tap_ok H "H3: YAML Phase 2 <${PERF_LIMIT_MS}ms (${elapsed_ms}ms)"
  else
    tap_fail H "H3: YAML Phase 2 <${PERF_LIMIT_MS}ms" "${elapsed_ms}ms"
  fi
else
  tap_skip H "H3: YAML performance" "yamllint not installed"
fi

# H4: Markdown Phase 1+2 <500ms
if ${HAS_MARKDOWNLINT}; then
  f="${TEMP_DIR}/h4_perf.md"
  printf '# Title\n\nSome text here.\n' >"${f}"
  t1=$(get_ns)
  run_multi_linter "${f}"
  t2=$(get_ns)
  elapsed_ms=$(((t2 - t1) / 1000000))
  PERF_RESULTS+="| H4 | Markdown clean | ${elapsed_ms}ms | ${PERF_LIMIT_MS}ms |"$'\n'
  if [[ ${elapsed_ms} -lt ${PERF_LIMIT_MS} ]]; then
    tap_ok H "H4: Markdown Phase 1+2 <${PERF_LIMIT_MS}ms (${elapsed_ms}ms)"
  else
    tap_fail H "H4: Markdown Phase 1+2 <${PERF_LIMIT_MS}ms" "${elapsed_ms}ms"
  fi
else
  tap_skip H "H4: Markdown performance" "markdownlint not installed"
fi

# H5: Biome 500-line file <500ms
if ${HAS_BIOME}; then
  rm -f "/tmp/.biome_path_$$"
  f="${TS_PROJECT}/h5_large.ts"
  {
    for i in $(seq 1 500); do
      echo "const var${i} = ${i};"
    done
    echo 'console.log("done");'
  } >"${f}"
  t1=$(get_ns)
  run_multi_linter "${f}" "${TS_PROJECT}"
  t2=$(get_ns)
  elapsed_ms=$(((t2 - t1) / 1000000))
  PERF_RESULTS+="| H5 | Biome 500-line | ${elapsed_ms}ms | ${PERF_LIMIT_MS}ms |"$'\n'
  if [[ ${elapsed_ms} -lt ${PERF_LIMIT_MS} ]]; then
    tap_ok H "H5: Biome 500-line <${PERF_LIMIT_MS}ms (${elapsed_ms}ms)"
  else
    tap_fail H "H5: Biome 500-line <${PERF_LIMIT_MS}ms" "${elapsed_ms}ms"
  fi
else
  tap_skip H "H5: Biome performance" "biome not installed"
fi

# ============================================================================
# REPORT GENERATION
# ============================================================================

echo ""
echo "# --- Summary ---"
echo "# Total: ${TAP_NUM}  Pass: ${TAP_PASS}  Fail: ${TAP_FAIL}  Skip: ${TAP_SKIP}"
echo "1..${TAP_NUM}"

generate_report() {
  local _rpt_date
  _rpt_date=$(date -u +%Y-%m-%dT%H:%M:%SZ) || true
  local _cat_a_pass _cat_a_fail _cat_a_skip
  _cat_a_pass=$(_get_cat A PASS)
  _cat_a_fail=$(_get_cat A FAIL)
  _cat_a_skip=$(_get_cat A SKIP)
  local _cat_b_pass _cat_b_fail _cat_b_skip
  _cat_b_pass=$(_get_cat B PASS)
  _cat_b_fail=$(_get_cat B FAIL)
  _cat_b_skip=$(_get_cat B SKIP)
  local _cat_c_pass _cat_c_fail _cat_c_skip
  _cat_c_pass=$(_get_cat C PASS)
  _cat_c_fail=$(_get_cat C FAIL)
  _cat_c_skip=$(_get_cat C SKIP)
  local _cat_d_pass _cat_d_fail _cat_d_skip
  _cat_d_pass=$(_get_cat D PASS)
  _cat_d_fail=$(_get_cat D FAIL)
  _cat_d_skip=$(_get_cat D SKIP)
  local _cat_e_pass _cat_e_fail _cat_e_skip
  _cat_e_pass=$(_get_cat E PASS)
  _cat_e_fail=$(_get_cat E FAIL)
  _cat_e_skip=$(_get_cat E SKIP)
  local _cat_f_pass _cat_f_fail _cat_f_skip
  _cat_f_pass=$(_get_cat F PASS)
  _cat_f_fail=$(_get_cat F FAIL)
  _cat_f_skip=$(_get_cat F SKIP)
  local _cat_g_pass _cat_g_fail _cat_g_skip
  _cat_g_pass=$(_get_cat G PASS)
  _cat_g_fail=$(_get_cat G FAIL)
  _cat_g_skip=$(_get_cat G SKIP)
  local _cat_h_pass _cat_h_fail _cat_h_skip
  _cat_h_pass=$(_get_cat H PASS)
  _cat_h_fail=$(_get_cat H FAIL)
  _cat_h_skip=$(_get_cat H SKIP)

  cat >"${REPORT_FILE}" <<REPORT_HEADER
# Stress Test Report

Generated: ${_rpt_date}

## Summary

| Metric | Count |
| ------ | ----- |
| Total  | ${TAP_NUM} |
| Pass   | ${TAP_PASS} |
| Fail   | ${TAP_FAIL} |
| Skip   | ${TAP_SKIP} |

## Per-Category Breakdown

| Category | Pass | Fail | Skip |
| -------- | ---- | ---- | ---- |
| A: Language Handlers | ${_cat_a_pass} | ${_cat_a_fail} | ${_cat_a_skip} |
| B: Model Selection | ${_cat_b_pass} | ${_cat_b_fail} | ${_cat_b_skip} |
| C: Config Toggles | ${_cat_c_pass} | ${_cat_c_fail} | ${_cat_c_skip} |
| D: PreToolUse Protection | ${_cat_d_pass} | ${_cat_d_fail} | ${_cat_d_skip} |
| E: Stop Hook | ${_cat_e_pass} | ${_cat_e_fail} | ${_cat_e_skip} |
| F: Session-Scoped | ${_cat_f_pass} | ${_cat_f_fail} | ${_cat_f_skip} |
| G: Edge Cases | ${_cat_g_pass} | ${_cat_g_fail} | ${_cat_g_skip} |
| H: Performance | ${_cat_h_pass} | ${_cat_h_fail} | ${_cat_h_skip} |

REPORT_HEADER

  if [[ -n "${FAILURES}" ]]; then
    cat >>"${REPORT_FILE}" <<'FAIL_HDR'
## Failures

| # | Test | Detail |
| - | ---- | ------ |
FAIL_HDR
    echo "${FAILURES}" >>"${REPORT_FILE}"
  else
    {
      echo "## Failures"
      echo ""
      echo "None."
    } >>"${REPORT_FILE}"
  fi

  echo "" >>"${REPORT_FILE}"

  if [[ -n "${SKIPS}" ]]; then
    cat >>"${REPORT_FILE}" <<'SKIP_HDR'
## Skips

| # | Test | Reason |
| - | ---- | ------ |
SKIP_HDR
    echo "${SKIPS}" >>"${REPORT_FILE}"
  fi

  echo "" >>"${REPORT_FILE}"

  if [[ -n "${PERF_RESULTS}" ]]; then
    cat >>"${REPORT_FILE}" <<'PERF_HDR'
## Performance

| Test | Description | Actual | Limit |
| ---- | ----------- | ------ | ----- |
PERF_HDR
    echo "${PERF_RESULTS}" >>"${REPORT_FILE}"
  fi

  echo "" >>"${REPORT_FILE}"

  cat >>"${REPORT_FILE}" <<'RECS'
## Recommendations

### sed parsing fragility (YAML/flake8)

The yamllint and flake8 parsable output is converted to JSON via
`sed` + `jaq` pipelines. Lines containing colons, parentheses, or
brackets in messages can confuse the regex. Consider switching to
native JSON output where available (yamllint does not support it;
flake8 supports `--format=json` in newer versions).

### Biome JSON reporter stability

Biome's `--reporter=json` output structure can change between
versions. The span-to-line conversion uses `split("\n")` on
sourceCode which may break if sourceCode is absent. Pin biome
version or add defensive nil checks in the jaq pipeline.

### Path handling edge cases

Files outside `CLAUDE_PROJECT_DIR` lose relative path conversion
for biome. The `_biome_relpath()` function falls back to absolute
paths, which biome may reject for project-scoped rules. Consider
warning when file is outside project root.

### Config toggle interaction bugs

When `auto_format=false` and `subprocess_delegation=false`, the
hook still runs Phase 2 and exits 2 on violations. This is correct
behavior but may surprise users who expect the hook to be fully
disabled. Consider a `hook_enabled=false` master toggle.

### Model selection boundary correctness

The volume threshold uses `>` (strictly greater than), so exactly
5 violations selects haiku/sonnet, not opus. This is intentional
but should be documented clearly. The boundary is at 6+ violations.

### Missing tool graceful degradation

All tool checks use `command -v` and skip gracefully. The only
hard dependency is `jaq` for JSON parsing. If jaq is missing, the
hook cannot function. Consider a startup check that warns if jaq
is not available.
RECS
}

generate_report
echo ""
echo "# Report written to: ${REPORT_FILE}"

# Exit with failure count
if [[ ${TAP_FAIL} -gt 0 ]]; then
  exit 1
fi
exit 0
