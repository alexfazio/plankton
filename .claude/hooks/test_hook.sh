#!/bin/bash
# test_hook.sh - Test multi_linter.sh with sample input
# shellcheck disable=SC2317  # indirect callback functions throughout
#
# Usage: ./test_hook.sh <file_path>
#        ./test_hook.sh --self-test
#
# Simulates the JSON input that Claude Code sends to PostToolUse hooks
# Useful for debugging hook behavior without running Claude Code

set -euo pipefail

script_dir="$(dirname "$(realpath "$0" || true)")"
project_dir="$(dirname "$(dirname "${script_dir}")")"

# Self-test mode: comprehensive automated testing
run_self_test() {
  local passed=0
  local failed=0
  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf "${temp_dir}"; rm -f "${project_dir}/test_fixture_broken.toml" /tmp/.biome_path_$$ /tmp/.semgrep_session_$$ /tmp/.semgrep_session_$$.done /tmp/.jscpd_ts_session_$$ /tmp/.jscpd_session_$$ /tmp/.sfc_warned_*_$$ /tmp/.nursery_checked_$$ /tmp/.pm_warn_*_$$ /tmp/.pm_test_stderr_$$ /tmp/.pm_enforcement_$$.log' EXIT


  # --- Shared test fixture (decouples tests from production config) ---
  local fixture_project_dir="${temp_dir}/fixture_project"
  mkdir -p "${fixture_project_dir}/.claude/hooks"
  cp "${script_dir}/../tests/hooks/fixtures/config.json" \
    "${fixture_project_dir}/.claude/hooks/config.json"
  # markdownlint-cli2 discovers config by walking up from the linted file
  cp "${script_dir}/../tests/hooks/fixtures/.markdownlint-cli2.jsonc" \
    "${fixture_project_dir}/.markdownlint-cli2.jsonc"
  # Copy .markdownlint.jsonc rules file from fixtures
  local fixtures_dir="${script_dir}/../tests/hooks/fixtures"
  cp "${fixtures_dir}/.markdownlint.jsonc" \
    "${fixture_project_dir}/.markdownlint.jsonc"
  echo "=== Hook Self-Test Suite ==="
  echo ""

  # Test helper for temp files (creates file with content)
  # Uses HOOK_SKIP_SUBPROCESS=1 to test detection without subprocess fixing
  test_temp_file() {
    local name="$1"
    local file="$2"
    local content="$3"
    local expect_exit="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 CLAUDE_PROJECT_DIR="${fixture_project_dir}" "${script_dir}/multi_linter.sh" >/dev/null 2>&1
    local actual_exit=$?
    set -e

    if [[ "${actual_exit}" -eq "${expect_exit}" ]]; then
      echo "PASS ${name}: exit ${actual_exit} (expected ${expect_exit})"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: exit ${actual_exit} (expected ${expect_exit})"
      failed=$((failed + 1))
    fi
  }

  # Test helper for package manager hook (enforce_package_managers.sh)
  # Sends a Bash tool_input.command JSON to the PM hook and checks the decision.
  test_bash_command() {
    local name="$1"           # Test name
    local command_str="$2"    # Command to test
    local expected="$3"       # "approve" or "block"
    local pm_dir="$4"         # CLAUDE_PROJECT_DIR override (temp dir with config)
    local extra_check="${5:-}" # Optional: string to grep in stdout+stderr

    local json_input="{\"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"${command_str}\"}}"
    set +e
    local output stderr_output
    output=$(echo "${json_input}" | CLAUDE_PROJECT_DIR="${pm_dir}" \
      "${script_dir}/enforce_package_managers.sh" 2>/tmp/.pm_test_stderr_$$)
    local actual_exit=$?
    stderr_output=$(cat /tmp/.pm_test_stderr_$$ 2>/dev/null || true)
    rm -f /tmp/.pm_test_stderr_$$
    set -e

    local decision
    decision=$(echo "${output}" | jaq -r '.decision // "none"' 2>/dev/null || echo "none")

    local pass=true
    [[ "${decision}" != "${expected}" ]] && pass=false
    if [[ -n "${extra_check}" ]]; then
      echo "${output}${stderr_output}" | grep -qF "${extra_check}" || pass=false
    fi

    if "${pass}"; then
      echo "PASS ${name}: decision=${decision}"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: decision=${decision} (expected ${expected})"
      [[ -n "${extra_check}" ]] && echo "   extra_check='${extra_check}' not found"
      echo "   stdout: ${output}"
      echo "   stderr: ${stderr_output}"
      failed=$((failed + 1))
    fi
  }

  # _create_mock_path_without(exclude_tool, mock_dir)
  # Creates mock_dir with symlinks to all tools used by the hook scripts,
  # EXCLUDING the specified tool. Used for "tool not installed" tests.
  _create_mock_path_without() {
    local exclude_tool="$1"
    local mock_dir="$2"
    mkdir -p "${mock_dir}"
    local t t_path
    for t in jaq grep sed tr head cat touch bash; do
      [[ "${t}" == "${exclude_tool}" ]] && continue
      t_path=$(command -v "${t}" 2>/dev/null || true)
      if [[ -n "${t_path}" ]]; then
        ln -sf "${t_path}" "${mock_dir}/${t}" 2>/dev/null || true
      fi
    done
  }

  # Dockerfile pattern tests
  echo "--- Dockerfile Pattern Coverage ---"
  test_temp_file "Dockerfile (valid)" \
    "${temp_dir}/Dockerfile" \
    'FROM python:3.11-slim
LABEL maintainer="test" version="1.0"
CMD ["python"]' 0

  test_temp_file "*.dockerfile (valid)" \
    "${temp_dir}/test.dockerfile" \
    'FROM alpine:3.19
LABEL maintainer="test" version="1.0"
CMD ["echo"]' 0

  test_temp_file "*.dockerfile (invalid - missing labels)" \
    "${temp_dir}/bad.dockerfile" \
    'FROM ubuntu
RUN apt-get update' 2

  # Other file type tests
  echo ""
  echo "--- Other File Types ---"
  # Python needs proper docstrings now that D rules are enabled
  test_temp_file "Python (valid)" \
    "${temp_dir}/test.py" \
    '"""Module docstring."""


def foo():
    """Do nothing."""
    pass' 0

  test_temp_file "Shell (valid)" \
    "${temp_dir}/test.sh" \
    '#!/bin/bash
echo "hello"' 0

  test_temp_file "JSON (valid)" \
    "${temp_dir}/test.json" \
    '{"key": "value"}' 0

  test_temp_file "JSON (invalid syntax)" \
    "${temp_dir}/bad.json" \
    '{invalid}' 2

  test_temp_file "YAML (valid)" \
    "${temp_dir}/test.yaml" \
    'key: value' 0

  # Styled output format tests
  # Uses HOOK_SKIP_SUBPROCESS=1 to capture output without subprocess
  echo ""
  echo "--- Styled Output Format Tests ---"

  test_output_format() {
    local name="$1"
    local file="$2"
    local content="$3"
    local pattern="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    local output
    output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 CLAUDE_PROJECT_DIR="${fixture_project_dir}" "${script_dir}/multi_linter.sh" 2>&1)
    set -e

    if echo "${output}" | grep -qE "${pattern}"; then
      echo "PASS ${name}: pattern '${pattern}' found"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: pattern '${pattern}' NOT found"
      echo "   Output: ${output}"
      failed=$((failed + 1))
    fi
  }

  # Test violations output contains JSON_SYNTAX code
  test_output_format "JSON violations output" \
    "${temp_dir}/marked.json" \
    '{invalid}' \
    'JSON_SYNTAX'

  # Test Dockerfile violations are captured
  test_output_format "Dockerfile violations captured" \
    "${temp_dir}/blend.dockerfile" \
    'FROM ubuntu
RUN apt-get update' \
    'DL[0-9]+'

  # Model selection tests (new three-phase architecture)
  echo ""
  echo "--- Model Selection Tests ---"

  test_model_selection() {
    local name="$1"
    local file="$2"
    local content="$3"
    local expect_model="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    local output
    output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 HOOK_DEBUG_MODEL=1 CLAUDE_PROJECT_DIR="${fixture_project_dir}" "${script_dir}/multi_linter.sh" 2>&1)
    set -e

    local actual_model
    actual_model=$(echo "${output}" | grep -oE '\[hook:model\] (haiku|sonnet|opus)' | awk '{print $2}' || echo "none")

    if [[ "${actual_model}" == "${expect_model}" ]]; then
      echo "PASS ${name}: model=${actual_model} (expected ${expect_model})"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: model=${actual_model} (expected ${expect_model})"
      failed=$((failed + 1))
    fi
  }

  # Simple violation -> haiku (needs docstrings to avoid D rules triggering sonnet)
  test_model_selection "Simple (F841) -> haiku" \
    "${temp_dir}/simple.py" \
    '"""Module docstring."""


def foo():
    """Do nothing."""
    unused = 1
    return 42' \
    "haiku"

  # Complexity violation -> sonnet (PLR0913 too many args, <=5 total violations)
  test_model_selection "Complexity (PLR0913) -> sonnet" \
    "${temp_dir}/complex.py" \
    '"""Module docstring."""


def process(one, two, three, four, five, six):
    """Process with too many args."""
    return one + two + three + four + five + six' \
    "sonnet"

  # >5 violations -> opus (needs docstrings, 6 F841 unused variables)
  test_model_selection ">5 violations -> opus" \
    "${temp_dir}/many.py" \
    '"""Module docstring."""


def foo():
    """Create unused variables."""
    a = 1
    b = 2
    c = 3
    d = 4
    e = 5
    f = 6
    return 42' \
    "opus"

  # Docstring violation -> sonnet
  test_model_selection "Docstring (D103) -> sonnet" \
    "${temp_dir}/nodoc.py" \
    'def missing_docstring():
    return 42' \
    "sonnet"

  # TypeScript tests (gated on Biome availability)
  echo ""
  echo "--- TypeScript Tests ---"

  # Create a temp project directory with TS-enabled config
  ts_project_dir="${temp_dir}/ts_project"
  mkdir -p "${ts_project_dir}/.claude/hooks"
  cat > "${ts_project_dir}/.claude/hooks/config.json" << 'TS_CFG_EOF'
{
  "languages": {
    "python": true, "shell": true, "yaml": true, "json": true,
    "toml": true, "dockerfile": true, "markdown": true,
    "typescript": {
      "enabled": true, "js_runtime": "auto", "biome_nursery": "warn",
      "biome_unsafe_autofix": false, "semgrep": false, "knip": false
    }
  },
  "phases": { "auto_format": true, "subprocess_delegation": true },
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "SC[0-9]+|E[0-9]+|W[0-9]+|F[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "C901|PLR[0-9]+|complexity|useExhaustiveDependencies|noExplicitAny", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "unresolved-attribute|type-assertion", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}
TS_CFG_EOF

  # Helper: run TS test with TS-enabled config
  test_ts_file() {
    local name="$1"
    local file="$2"
    local content="$3"
    local expect_exit="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${ts_project_dir}" \
      "${script_dir}/multi_linter.sh" >/dev/null 2>&1
    local actual_exit=$?
    set -e

    if [[ "${actual_exit}" -eq "${expect_exit}" ]]; then
      echo "PASS ${name}: exit ${actual_exit} (expected ${expect_exit})"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: exit ${actual_exit} (expected ${expect_exit})"
      failed=$((failed + 1))
    fi
  }

  # Helper: run TS test and check stderr output
  test_ts_output() {
    local name="$1"
    local file="$2"
    local content="$3"
    local pattern="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    local output
    output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${ts_project_dir}" \
      "${script_dir}/multi_linter.sh" 2>&1)
    set -e

    if echo "${output}" | grep -qE "${pattern}"; then
      echo "PASS ${name}: pattern '${pattern}' found"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: pattern '${pattern}' NOT found"
      echo "   Output: ${output}"
      failed=$((failed + 1))
    fi
  }

  # Detect Biome for gating
  biome_cmd=""
  if [[ -x "${project_dir}/node_modules/.bin/biome" ]]; then
    biome_cmd="${project_dir}/node_modules/.bin/biome"
  elif command -v biome >/dev/null 2>&1; then
    biome_cmd="biome"
  fi

  if [[ -n "${biome_cmd}" ]]; then
    # Test 1: Clean TS file -> exit 0
    test_ts_file "TS clean file" \
      "${temp_dir}/clean.ts" \
      'const greeting: string = "hello";
console.log(greeting);' 0

    # Test 2: TS unused var -> exit 2
    test_ts_file "TS unused variable" \
      "${temp_dir}/unused.ts" \
      'const used = "hello";
const unused = "world";
console.log(used);' 2

    # Test 3: JS file handling -> exit 0
    test_ts_file "JS clean file" \
      "${temp_dir}/clean.js" \
      'const x = 1;
console.log(x);' 0

    # Test 4: JSX with a11y issue -> exit 2
    test_ts_file "JSX a11y violation" \
      "${temp_dir}/bad.jsx" \
      'function App() {
  return <img src="photo.jpg" />;
}' 2

    # Test 5: Config: TS disabled -> exit 0 (skip)
    # Uses its own config fixture with typescript disabled
    ts_disabled_dir="${temp_dir}/ts_disabled_project"
    mkdir -p "${ts_disabled_dir}/.claude/hooks"
    cat > "${ts_disabled_dir}/.claude/hooks/config.json" << 'TS_DIS_EOF'
{
  "languages": {
    "python": true, "shell": true, "yaml": true, "json": true,
    "toml": true, "dockerfile": true, "markdown": true,
    "typescript": false
  },
  "phases": { "auto_format": true, "subprocess_delegation": true }
}
TS_DIS_EOF
    local ts_dis_file="${temp_dir}/skipped.ts"
    echo 'const unused = "should be skipped";' > "${ts_dis_file}"
    local ts_dis_json='{"tool_input": {"file_path": "'"${ts_dis_file}"'"}}'
    set +e
    echo "${ts_dis_json}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${ts_disabled_dir}" \
      "${script_dir}/multi_linter.sh" >/dev/null 2>&1
    local ts_dis_exit=$?
    set -e
    if [[ "${ts_dis_exit}" -eq 0 ]]; then
      echo "PASS TS disabled skips: exit ${ts_dis_exit} (expected 0)"
      passed=$((passed + 1))
    else
      echo "FAIL TS disabled skips: exit ${ts_dis_exit} (expected 0)"
      failed=$((failed + 1))
    fi

    # Test 6: CSS clean -> exit 0
    test_ts_file "CSS clean file" \
      "${temp_dir}/clean.css" \
      'body {
  margin: 0;
  padding: 0;
}' 0

    # Test 7: CSS violations -> exit 2
    test_ts_file "CSS violation" \
      "${temp_dir}/bad.css" \
      'a { colr: red; }' 2

    # Test 8: Biome violations output contains category
    test_ts_output "TS violations output" \
      "${temp_dir}/output.ts" \
      'const used = 1;
const unused = 2;
console.log(used);' \
      'biome'

    # Test 9: Nursery advisory output
    # Nursery rules require biome.json in project root with explicit
    # nursery config; default biome config has no lint/nursery/ rules.
    # Conditionally test if a nursery rule fires on the fixture.
    echo "${temp_dir}/nursery.ts" > /dev/null  # placeholder path
    local nursery_file="${temp_dir}/nursery.ts"
    printf 'const foo = "bar";\nfunction f() { const foo = 1; console.log(foo); }\nf();\nconsole.log(foo);\n' > "${nursery_file}"
    local nursery_json='{"tool_input": {"file_path": "'"${nursery_file}"'"}}'
    set +e
    local nursery_out
    nursery_out=$(echo "${nursery_json}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${ts_project_dir}" \
      "${script_dir}/multi_linter.sh" 2>&1)
    set -e
    if echo "${nursery_out}" | grep -qE 'hook:advisory'; then
      echo "PASS TS nursery advisory: pattern 'hook:advisory' found"
      passed=$((passed + 1))
    else
      echo "[skip] #9 TS nursery advisory (no nursery rules in default biome config)"
    fi

    # Test 10: Protected biome.json
    echo ""
    echo "--- TypeScript Protection Tests ---"
    local biome_protect_result
    biome_protect_result=$(echo '{"tool_input":{"file_path":"biome.json"}}' \
      | CLAUDE_PROJECT_DIR="${ts_project_dir}" \
        "${script_dir}/protect_linter_configs.sh" 2>/dev/null)
    if echo "${biome_protect_result}" | grep -q '"block"'; then
      echo "PASS Protected: biome.json blocked"
      passed=$((passed + 1))
    else
      echo "FAIL Protected: biome.json not blocked"
      echo "   Output: ${biome_protect_result}"
      failed=$((failed + 1))
    fi

    # Test 11: Model selection for TS - simple -> haiku
    echo ""
    echo "--- TypeScript Model Selection Tests ---"

    test_ts_model() {
      local name="$1"
      local file="$2"
      local content="$3"
      local expect_model="$4"

      echo "${content}" >"${file}"
      local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
      set +e
      local output
      output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 HOOK_DEBUG_MODEL=1 \
        CLAUDE_PROJECT_DIR="${ts_project_dir}" \
        "${script_dir}/multi_linter.sh" 2>&1)
      set -e

      local actual_model
      actual_model=$(echo "${output}" | grep -oE '\[hook:model\] (haiku|sonnet|opus)' \
        | awk '{print $2}' || echo "none")

      if [[ "${actual_model}" == "${expect_model}" ]]; then
        echo "PASS ${name}: model=${actual_model} (expected ${expect_model})"
        passed=$((passed + 1))
      else
        echo "FAIL ${name}: model=${actual_model} (expected ${expect_model})"
        failed=$((failed + 1))
      fi
    }

    test_ts_model "TS simple -> haiku" \
      "${temp_dir}/ts_simple.ts" \
      'const used = 1;
const unused = 2;
console.log(used);' \
      "haiku"

    # Test 12: Model selection for TS - sonnet (type-aware rule)
    test_ts_model "TS type-aware -> sonnet" \
      "${temp_dir}/ts_sonnet.ts" \
      'const x: any = 1;
console.log(x);' \
      "sonnet"

    # Test 13: Model selection for TS - >5 violations -> opus
    test_ts_model "TS >5 violations -> opus" \
      "${temp_dir}/ts_many.ts" \
      'const a = 1;
const b = 2;
const c = 3;
const d = 4;
const e = 5;
const f = 6;
console.log("none used");' \
      "opus"

    # Test 14: JSON via Biome when TS enabled (D6)
    test_ts_file "JSON via Biome (D6)" \
      "${temp_dir}/biome_json.json" \
      '{"key": "value"}' 0

    # Test 15: SFC file warning (D4)
    if ! command -v semgrep >/dev/null 2>&1; then
      local sfc_file="${temp_dir}/component.vue"
      printf '<script>export default {}</script>\n' > "${sfc_file}"
      local sfc_json='{"tool_input":{"file_path":"'"${sfc_file}"'"}}'
      set +e
      local sfc_out
      sfc_out=$(echo "${sfc_json}" | HOOK_SKIP_SUBPROCESS=1 \
        CLAUDE_PROJECT_DIR="${ts_project_dir}" \
        "${script_dir}/multi_linter.sh" 2>&1)
      set -e
      if echo "${sfc_out}" | grep -q 'hook:warning'; then
        echo "PASS SFC warning for .vue"
        passed=$((passed + 1))
      else
        echo "FAIL SFC warning for .vue"
        echo "   Output: ${sfc_out}"
        failed=$((failed + 1))
      fi
    else
      echo "[skip] #15 SFC warning (semgrep installed)"
    fi

    # Test 16: D3 oxlint overlap — nursery rules actually skipped
    local d3_dir="${temp_dir}/d3_project"
    mkdir -p "${d3_dir}/.claude/hooks"
    cat > "${d3_dir}/.claude/hooks/config.json" << 'D3_CFG_EOF'
{
  "languages": {
    "typescript": {
      "enabled": true, "oxlint_tsgolint": true,
      "biome_nursery": "warn", "semgrep": false
    }
  },
  "phases": {"auto_format": true, "subprocess_delegation": true},
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "SC[0-9]+|E[0-9]+|W[0-9]+|F[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "C901", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "x", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}
D3_CFG_EOF
    # biome.json enables the nursery rule so it would fire without --skip
    cat > "${d3_dir}/biome.json" << 'D3_BIOME_EOF'
{
  "linter": {
    "rules": {
      "nursery": {
        "noFloatingPromises": "error"
      }
    }
  }
}
D3_BIOME_EOF
    # tsconfig.json required for type-aware nursery rules
    cat > "${d3_dir}/tsconfig.json" << 'D3_TS_EOF'
{
  "compilerOptions": {
    "strict": true,
    "target": "es2020",
    "module": "es2020",
    "moduleResolution": "bundler"
  },
  "include": ["*.ts"]
}
D3_TS_EOF
    # File with floating promise (triggers noFloatingPromises)
    local d3_file="${d3_dir}/d3_test.ts"
    cat > "${d3_file}" << 'D3_SRC_EOF'
async function fetchData(): Promise<string> {
  return "data";
}
fetchData();
const unused = 1;
console.log("test");
D3_SRC_EOF
    local d3_json='{"tool_input":{"file_path":"'"${d3_file}"'"}}'
    set +e
    local d3_out
    d3_out=$(echo "${d3_json}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${d3_dir}" \
      "${script_dir}/multi_linter.sh" 2>&1)
    set -e
    # With oxlint_tsgolint=true, --skip suppresses the 3 overlap rules
    # Match lint violation format (lint/nursery/...) not config warnings
    if echo "${d3_out}" | grep -qE \
        'lint/nursery/noFloatingPromises|lint/nursery/noMisusedPromises|lint/nursery/useAwaitThenable'; then
      echo "FAIL D3 overlap: disabled rules still reported"
      echo "   Output: ${d3_out}"
      failed=$((failed + 1))
    else
      echo "PASS D3 overlap: nursery rules skipped"
      passed=$((passed + 1))
    fi

  else
    echo "[skip] Biome not installed - skipping TypeScript tests"
    echo "       Install: npm i -D @biomejs/biome"
  fi

  # Fallback: Biome not installed -> exit 0 + warning
  echo ""
  echo "--- TypeScript Fallback Tests ---"
  # Create a config that forces a non-existent biome path
  no_biome_dir="${temp_dir}/no_biome_project"
  mkdir -p "${no_biome_dir}/.claude/hooks"
  # Use js_runtime: "none" to force detect_biome() to find nothing
  cat > "${no_biome_dir}/.claude/hooks/config.json" << 'NOBIOME_EOF'
{
  "languages": {
    "typescript": {
      "enabled": true, "js_runtime": "none", "semgrep": false
    }
  },
  "phases": { "auto_format": true, "subprocess_delegation": true },
  "subprocess": {
    "tiers": {
      "haiku": {"patterns": "SC[0-9]+|E[0-9]+|W[0-9]+|F[0-9]+", "tools": "Edit,Read", "max_turns": 10, "timeout": 120},
      "sonnet": {"patterns": "C901", "tools": "Edit,Read", "max_turns": 10, "timeout": 300},
      "opus": {"patterns": "unresolved-attribute", "tools": "Edit,Read,Write", "max_turns": 15, "timeout": 600}
    },
    "global_model_override": null,
    "max_turns_override": null,
    "timeout_override": null,
    "volume_threshold": 5,
    "settings_file": null
  }
}
NOBIOME_EOF

  no_biome_content='const x = 1;
console.log(x);'
  echo "${no_biome_content}" > "${temp_dir}/no_biome.ts"
  no_biome_json='{"tool_input": {"file_path": "'"${temp_dir}/no_biome.ts"'"}}'
  set +e
  echo "${no_biome_json}" | HOOK_SKIP_SUBPROCESS=1 \
    CLAUDE_PROJECT_DIR="${no_biome_dir}" \
    "${script_dir}/multi_linter.sh" >/dev/null 2>&1
  no_biome_exit=$?
  set -e

  if [[ "${no_biome_exit}" -eq 0 ]]; then
    echo "PASS Biome not installed -> exit 0"
    passed=$((passed + 1))
  else
    echo "FAIL Biome not installed -> exit ${no_biome_exit} (expected 0)"
    failed=$((failed + 1))
  fi

  # Tests 17-21: Deferred tool tests (ADR Q6)
  echo ""
  echo "--- Deferred Tool Tests (placeholders) ---"
  echo "[skip] #17 oxlint: type-aware violation (deferred)"
  echo "[skip] #18 oxlint: disabled default (deferred)"
  echo "[skip] #19 oxlint: timeout gate (deferred)"
  echo "[skip] #20 tsgo: session advisory (deferred)"
  echo "[skip] #21 tsgo: disabled default (deferred)"

  # ============================================================
  # Package Manager Enforcement Tests
  # ============================================================
  echo ""
  echo "--- Package Manager Enforcement Tests ---"

  # Create test config directories
  pm_project_dir="${temp_dir}/pm_project"
  pm_warn_py_dir="${temp_dir}/pm_warn_py"
  pm_warn_js_dir="${temp_dir}/pm_warn_js"
  pm_off_py_dir="${temp_dir}/pm_off_py"
  pm_off_js_dir="${temp_dir}/pm_off_js"

  for d in "${pm_project_dir}" "${pm_warn_py_dir}" "${pm_warn_js_dir}" \
            "${pm_off_py_dir}" "${pm_off_js_dir}"; do
    mkdir -p "${d}/.claude/hooks"
  done

  # Default: both ecosystems block mode
  cat > "${pm_project_dir}/.claude/hooks/config.json" << 'PM_CFG_EOF'
{
  "package_managers": {
    "python": "uv",
    "javascript": "bun",
    "allowed_subcommands": {
      "npm": ["audit", "view", "pack", "publish", "whoami", "login"],
      "pip": ["download"],
      "yarn": ["audit", "info"],
      "pnpm": ["audit", "info"],
      "poetry": [],
      "pipenv": []
    }
  }
}
PM_CFG_EOF

  # python: warn, JS: block
  cat > "${pm_warn_py_dir}/.claude/hooks/config.json" << 'PM_WARN_PY_EOF'
{
  "package_managers": {
    "python": "uv:warn",
    "javascript": "bun",
    "allowed_subcommands": {
      "npm": ["audit", "view", "pack", "publish", "whoami", "login"],
      "pip": ["download"],
      "yarn": ["audit", "info"],
      "pnpm": ["audit", "info"],
      "poetry": [],
      "pipenv": []
    }
  }
}
PM_WARN_PY_EOF

  # python: block, JS: warn
  cat > "${pm_warn_js_dir}/.claude/hooks/config.json" << 'PM_WARN_JS_EOF'
{
  "package_managers": {
    "python": "uv",
    "javascript": "bun:warn",
    "allowed_subcommands": {
      "npm": ["audit", "view", "pack", "publish", "whoami", "login"],
      "pip": ["download"],
      "yarn": ["audit", "info"],
      "pnpm": ["audit", "info"],
      "poetry": [],
      "pipenv": []
    }
  }
}
PM_WARN_JS_EOF

  # python: disabled, JS: block
  cat > "${pm_off_py_dir}/.claude/hooks/config.json" << 'PM_OFF_PY_EOF'
{
  "package_managers": {
    "python": false,
    "javascript": "bun",
    "allowed_subcommands": {
      "npm": ["audit", "view", "pack", "publish", "whoami", "login"],
      "pip": ["download"],
      "yarn": ["audit", "info"],
      "pnpm": ["audit", "info"],
      "poetry": [],
      "pipenv": []
    }
  }
}
PM_OFF_PY_EOF

  # python: block, JS: disabled
  cat > "${pm_off_js_dir}/.claude/hooks/config.json" << 'PM_OFF_JS_EOF'
{
  "package_managers": {
    "python": "uv",
    "javascript": false,
    "allowed_subcommands": {
      "npm": ["audit", "view", "pack", "publish", "whoami", "login"],
      "pip": ["download"],
      "yarn": ["audit", "info"],
      "pnpm": ["audit", "info"],
      "poetry": [],
      "pipenv": []
    }
  }
}
PM_OFF_JS_EOF

  # --- Python Tests (block mode) ---
  echo ""
  echo "--- Python Tests (block mode) ---"
  test_bash_command "pip install blocked" \
    "pip install requests" "block" "${pm_project_dir}" "uv add requests"
  test_bash_command "pip3 blocked" \
    "pip3 install flask" "block" "${pm_project_dir}"
  test_bash_command "python -m pip blocked" \
    "python -m pip install pkg" "block" "${pm_project_dir}"
  test_bash_command "python3 -m pip blocked" \
    "python3 -m pip install pkg" "block" "${pm_project_dir}"
  test_bash_command "python -m venv blocked" \
    "python -m venv .venv" "block" "${pm_project_dir}" "uv venv"
  test_bash_command "poetry blocked" \
    "poetry add requests" "block" "${pm_project_dir}"
  test_bash_command "pipenv blocked" \
    "pipenv install" "block" "${pm_project_dir}"
  test_bash_command "uv pip passthrough" \
    "uv pip install -r req.txt" "approve" "${pm_project_dir}"
  test_bash_command "uv add passthrough" \
    "uv add requests" "approve" "${pm_project_dir}"
  test_bash_command "pip freeze blocked" \
    "pip freeze" "block" "${pm_project_dir}" "uv pip freeze"
  test_bash_command "pip list blocked" \
    "pip list" "block" "${pm_project_dir}" "uv pip list"
  test_bash_command "pip editable blocked" \
    "pip install -e ." "block" "${pm_project_dir}" "uv pip install -e ."
  test_bash_command "pip download allowed" \
    "pip download requests" "approve" "${pm_project_dir}"
  test_bash_command "bare pip blocked" \
    "pip" "block" "${pm_project_dir}"
  test_bash_command "bare poetry blocked" \
    "poetry" "block" "${pm_project_dir}"
  test_bash_command "poetry show blocked" \
    "poetry show" "block" "${pm_project_dir}"
  test_bash_command "poetry env blocked" \
    "poetry env use 3.11" "block" "${pm_project_dir}"
  test_bash_command "pipenv graph blocked" \
    "pipenv graph" "block" "${pm_project_dir}"
  test_bash_command "compound pip" \
    "cd /app && pip install flask" "block" "${pm_project_dir}"
  test_bash_command "pip diagnostic" \
    "pip --version" "approve" "${pm_project_dir}"
  test_bash_command "poetry diagnostic" \
    "poetry --help" "approve" "${pm_project_dir}"

  # --- JavaScript Tests (block mode) ---
  echo ""
  echo "--- JavaScript Tests (block mode) ---"
  test_bash_command "npm install blocked" \
    "npm install lodash" "block" "${pm_project_dir}" "bun add lodash"
  test_bash_command "npm run blocked" \
    "npm run build" "block" "${pm_project_dir}" "bun run build"
  test_bash_command "npm test blocked" \
    "npm test" "block" "${pm_project_dir}" "bun test"
  test_bash_command "npx blocked" \
    "npx create-react-app" "block" "${pm_project_dir}" "bunx create-react-app"
  test_bash_command "yarn blocked" \
    "yarn add lodash" "block" "${pm_project_dir}"
  test_bash_command "pnpm blocked" \
    "pnpm install" "block" "${pm_project_dir}"
  test_bash_command "npm audit allowed" \
    "npm audit" "approve" "${pm_project_dir}"
  test_bash_command "npm view allowed" \
    "npm view lodash" "approve" "${pm_project_dir}"
  test_bash_command "compound npm" \
    "npm install && npm run build" "block" "${pm_project_dir}"
  test_bash_command "bun passthrough" \
    "bun add lodash" "approve" "${pm_project_dir}"
  test_bash_command "bunx passthrough" \
    "bunx vite" "approve" "${pm_project_dir}"
  test_bash_command "bare yarn blocked" \
    "yarn" "block" "${pm_project_dir}"
  test_bash_command "bare pnpm blocked" \
    "pnpm" "block" "${pm_project_dir}"
  test_bash_command "yarn audit allowed" \
    "yarn audit" "approve" "${pm_project_dir}"
  test_bash_command "pnpm audit allowed" \
    "pnpm audit" "approve" "${pm_project_dir}"
  test_bash_command "pnpm info allowed" \
    "pnpm info lodash" "approve" "${pm_project_dir}"
  test_bash_command "npm -g install blocked" \
    "npm -g install foo" "block" "${pm_project_dir}"
  test_bash_command "npm --registry flag+allowlist" \
    "npm --registry=url audit" "approve" "${pm_project_dir}"
  test_bash_command "bare npm blocked" \
    "npm" "block" "${pm_project_dir}"
  test_bash_command "npm diagnostic" \
    "npm --version" "approve" "${pm_project_dir}"
  test_bash_command "cross-ecosystem compound" \
    "pip install && npm install" "block" "${pm_project_dir}"
  test_bash_command "npm+yarn compound" \
    "npm audit && yarn add lodash" "block" "${pm_project_dir}"

  # --- Config toggle tests ---
  echo ""
  echo "--- Config Toggle Tests ---"
  test_bash_command "python disabled" \
    "pip install requests" "approve" "${pm_off_py_dir}"
  test_bash_command "javascript disabled" \
    "npm install" "approve" "${pm_off_js_dir}"

  # --- Warn mode tests ---
  echo ""
  echo "--- Warn Mode Tests ---"
  test_bash_command "pip warn mode" \
    "pip install flask" "approve" "${pm_warn_py_dir}" "[hook:advisory]"
  test_bash_command "npm warn mode" \
    "npm install" "approve" "${pm_warn_js_dir}" "[hook:advisory]"
  test_bash_command "warn + allowlist" \
    "npm audit" "approve" "${pm_warn_js_dir}"
  test_bash_command "warn + diagnostic" \
    "pip --version" "approve" "${pm_warn_py_dir}"
  test_bash_command "compound warn" \
    "cd /app && pip install requests" "approve" "${pm_warn_py_dir}" "[hook:advisory]"
  test_bash_command "warn msg format" \
    "pip install flask" "approve" "${pm_warn_py_dir}" "uv add flask"

  # --- HOOK_SKIP_PM bypass ---
  echo ""
  echo "--- Bypass and Passthrough Tests ---"
  local skip_output
  skip_output=$(echo '{"tool_name": "Bash", "tool_input": {"command": "pip install requests"}}' \
    | HOOK_SKIP_PM=1 CLAUDE_PROJECT_DIR="${pm_project_dir}" \
      "${script_dir}/enforce_package_managers.sh" 2>/dev/null || true)
  local skip_decision
  skip_decision=$(echo "${skip_output}" | jaq -r '.decision // "none"' 2>/dev/null || echo "none")
  if [[ "${skip_decision}" == "approve" ]]; then
    echo "PASS HOOK_SKIP_PM bypass: decision=approve"
    passed=$((passed + 1))
  else
    echo "FAIL HOOK_SKIP_PM bypass: decision=${skip_decision} (expected approve)"
    failed=$((failed + 1))
  fi

  # --- Non-package command ---
  test_bash_command "non-package cmd" \
    "ls -la" "approve" "${pm_project_dir}"

  # --- jaq missing (fail-open) ---
  # Mock PATH without jaq to test fail-open behavior
  local mock_tools_dir="${temp_dir}/mock_tools_nojaq"
  mkdir -p "${mock_tools_dir}"
  # Create stub PATH that has everything except jaq
  local nojaq_output
  set +e
  nojaq_output=$(echo '{"tool_name": "Bash", "tool_input": {"command": "pip install requests"}}' \
    | PATH="${mock_tools_dir}" CLAUDE_PROJECT_DIR="${pm_project_dir}" \
      "${script_dir}/enforce_package_managers.sh" 2>/dev/null || echo '{"decision": "approve"}')
  set -e
  local nojaq_decision
  nojaq_decision=$(echo "${nojaq_output}" | jaq -r '.decision // "none"' 2>/dev/null || echo "none")
  if [[ "${nojaq_decision}" == "approve" ]]; then
    echo "PASS jaq missing (fail-open): decision=approve"
    passed=$((passed + 1))
  else
    echo "FAIL jaq missing (fail-open): decision=${nojaq_decision} (expected approve)"
    failed=$((failed + 1))
  fi

  echo ""
  echo "--- Coverage Completion Tests ---"
  test_bash_command "python3 -m venv blocked" \
    "python3 -m venv .venv" "block" "${pm_project_dir}" "uv venv"
  test_bash_command "bare pipenv blocked" \
    "pipenv" "block" "${pm_project_dir}"

  echo ""
  echo "--- Compound Tests ---"
  # Known limitation: uv pip passthrough approves whole compound command
  test_bash_command "uv+pip compound known-limitation" \
    "uv pip install -r req.txt && pip install flask" "approve" "${pm_project_dir}"
  # npm --version no-ops; regex finds second npm install in full string
  test_bash_command "npm diag+install compound" \
    "npm --version && npm install" "block" "${pm_project_dir}"
  # pip diag no-ops; independent poetry block catches poetry add (post-restructure)
  test_bash_command "pip diag+poetry compound" \
    "pip --version && poetry add requests" "block" "${pm_project_dir}"
  # same-tool diagnostic: substring matching finds blocked cmd at second position
  test_bash_command "pipenv diag+install compound" \
    "pipenv --version && pipenv install" "block" "${pm_project_dir}"
  # cross-tool: pip diag no-ops in elif chain; independent pipenv block
  # catches pipenv install in the same full string scan
  test_bash_command "pip diag+pipenv compound" \
    "pip --version && pipenv install" "block" "${pm_project_dir}"
  # same-tool: first if-branch finds poetry add (second occurrence);
  # --help fails [a-zA-Z]+ so diagnostic elif is never entered
  test_bash_command "poetry diag+add compound" \
    "poetry --help && poetry add requests" "block" "${pm_project_dir}"

  echo ""
  echo "--- Pip Download Variant ---"
  test_bash_command "pip download -d allowed" \
    "pip download -d ./dist requests" "approve" "${pm_project_dir}"

  echo ""
  echo "--- Tool Missing Warning Tests ---"
  local mock_nouv="${temp_dir}/mock_nouv"
  local mock_nobun="${temp_dir}/mock_nobun"
  _create_mock_path_without "uv" "${mock_nouv}"
  _create_mock_path_without "bun" "${mock_nobun}"

  # uv missing: pip install should block AND emit [hook:warning] about uv
  set +e
  local nouv_out nouv_err
  nouv_out=$(echo '{"tool_name":"Bash","tool_input":{"command":"pip install requests"}}' \
    | PATH="${mock_nouv}" CLAUDE_PROJECT_DIR="${pm_project_dir}" \
      "${script_dir}/enforce_package_managers.sh" 2>/tmp/.pm_test_stderr_$$)
  nouv_err=$(cat /tmp/.pm_test_stderr_$$ 2>/dev/null || true)
  rm -f /tmp/.pm_test_stderr_$$
  set -e
  local nouv_dec
  nouv_dec=$(echo "${nouv_out}" | jaq -r '.decision // "none"' 2>/dev/null || echo "none")
  if [[ "${nouv_dec}" == "block" ]] && echo "${nouv_err}" | grep -qF "[hook:warning]"; then
    echo "PASS uv missing warning: decision=block, warning emitted"
    passed=$((passed + 1))
  else
    echo "FAIL uv missing warning: decision=${nouv_dec}, stderr=${nouv_err}"
    failed=$((failed + 1))
  fi

  # bun missing: npm install should block AND emit [hook:warning] about bun
  set +e
  local nobun_out nobun_err
  nobun_out=$(echo '{"tool_name":"Bash","tool_input":{"command":"npm install lodash"}}' \
    | PATH="${mock_nobun}" CLAUDE_PROJECT_DIR="${pm_project_dir}" \
      "${script_dir}/enforce_package_managers.sh" 2>/tmp/.pm_test_stderr_$$)
  nobun_err=$(cat /tmp/.pm_test_stderr_$$ 2>/dev/null || true)
  rm -f /tmp/.pm_test_stderr_$$
  set -e
  local nobun_dec
  nobun_dec=$(echo "${nobun_out}" | jaq -r '.decision // "none"' 2>/dev/null || echo "none")
  if [[ "${nobun_dec}" == "block" ]] && echo "${nobun_err}" | grep -qF "[hook:warning]"; then
    echo "PASS bun missing warning: decision=block, warning emitted"
    passed=$((passed + 1))
  else
    echo "FAIL bun missing warning: decision=${nobun_dec}, stderr=${nobun_err}"
    failed=$((failed + 1))
  fi

  echo ""
  echo "--- Debug Mode Test ---"
  set +e
  local dbg_out dbg_err
  dbg_out=$(echo '{"tool_name":"Bash","tool_input":{"command":"pip install requests"}}' \
    | HOOK_DEBUG_PM=1 CLAUDE_PROJECT_DIR="${pm_project_dir}" \
      "${script_dir}/enforce_package_managers.sh" 2>/tmp/.pm_test_stderr_$$)
  dbg_err=$(cat /tmp/.pm_test_stderr_$$ 2>/dev/null || true)
  rm -f /tmp/.pm_test_stderr_$$
  set -e
  local dbg_dec
  dbg_dec=$(echo "${dbg_out}" | jaq -r '.decision // "none"' 2>/dev/null || echo "none")
  if [[ "${dbg_dec}" == "block" ]] && echo "${dbg_err}" | grep -qF "[hook:debug]"; then
    echo "PASS HOOK_DEBUG_PM: decision=block, debug line emitted"
    passed=$((passed + 1))
  else
    echo "FAIL HOOK_DEBUG_PM: decision=${dbg_dec}, stderr=${dbg_err}"
    failed=$((failed + 1))
  fi

  echo ""
  echo "--- Yarn Info Allowed ---"
  test_bash_command "yarn info allowed" \
    "yarn info lodash" "approve" "${pm_project_dir}"

  echo ""
  echo "--- jaq Error Protection Tests ---"

  # Test: no direct collected_violations jaq merge assignments
  local unprotected_merges
  # shellcheck disable=SC2016  # intentional literal grep pattern
  unprotected_merges=$(grep -c 'collected_violations=$(echo "${collected_violations}"' \
    "${script_dir}/multi_linter.sh" || true)
  if [[ "${unprotected_merges}" -eq 0 ]]; then
    echo "PASS jaq_merge_guard: no unprotected merge assignments"
    passed=$((passed + 1))
  else
    echo "FAIL jaq_merge_guard: ${unprotected_merges} unprotected merge(s) found"
    failed=$((failed + 1))
  fi

  local guarded_merges
  # shellcheck disable=SC2016  # intentional literal grep pattern
  guarded_merges=$(grep -c '_merged=$(echo "${collected_violations}"' \
    "${script_dir}/multi_linter.sh" || true)
  if [[ "${guarded_merges}" -ge 13 ]]; then
    echo "PASS jaq_merge_count: ${guarded_merges} guarded merge(s) (at least 13)"
    passed=$((passed + 1))
  else
    echo "FAIL jaq_merge_count: ${guarded_merges} guarded merge(s) (expected at least 13)"
    failed=$((failed + 1))
  fi

  local conv_fallbacks
  conv_fallbacks=$(grep -cE '\|\| (ty|bandit|sc|hl)_converted="\[\]"' \
    "${script_dir}/multi_linter.sh" || true)
  if [[ "${conv_fallbacks}" -ge 4 ]]; then
    echo "PASS jaq_conversion_guard: ${conv_fallbacks} conversion fallback(s) (at least 4)"
    passed=$((passed + 1))
  else
    echo "FAIL jaq_conversion_guard: ${conv_fallbacks} conversion fallback(s) (expected at least 4)"
    failed=$((failed + 1))
  fi

  echo ""
  echo "--- Feedback Loop Regression Tests ---"

  # Helper: capture stderr only and validate via check function.
  # Unlike test_output_format (merges stdout+stderr), this isolates stderr
  # for JSON structure validation of hook feedback output.
  test_stderr_json() {
    local name="$1" file="$2" content="$3" check_fn="$4"
    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    local stderr_output
    stderr_output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${fixture_project_dir}" \
      "${script_dir}/multi_linter.sh" 2>&1 >/dev/null)
    local actual_exit=$?
    set -e
    if "${check_fn}" "${stderr_output}" "${actual_exit}"; then
      echo "PASS ${name}"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}"
      echo "   exit=${actual_exit}"
      echo "   stderr: ${stderr_output:0:200}"
      failed=$((failed + 1))
    fi
  }

  # Check: exit 2 + [hook] prefix + valid JSON array + required keys.
  # Handles multi-line JSON and multiple [hook] lines (e.g. markdown
  # emits a debug summary before the JSON payload).
  _check_hook_json() {
    local stderr="$1" exit_code="$2"
    [[ "${exit_code}" -ne 2 ]] && return 1
    # Find line number of the LAST [hook] line
    local last_hook_info
    last_hook_info=$(echo "${stderr}" | grep -n '^\[hook\] ' | tail -1)
    [[ -z "${last_hook_info}" ]] && return 1
    local line_num="${last_hook_info%%:*}"
    # Extract everything from that line onward, strip prefix from first line
    local json_part
    json_part=$(echo "${stderr}" | tail -n +"${line_num}")
    json_part="${json_part#\[hook\] }"
    echo "${json_part}" | jaq 'type == "array"' 2>/dev/null \
      | grep -q 'true' || return 1
    # Check all 5 unified schema keys: all handlers now convert to
    # {line, column, code, message, linter} during Phase 2 collection.
    local valid
    valid=$(echo "${json_part}" | jaq '[.[] |
      has("line") and has("column") and has("code")
      and has("message") and has("linter")] | all' 2>/dev/null)
    [[ "${valid}" != "true" ]] && return 1
    return 0
  }

  # Structural: rerun_phase2 call has | tail -1 guard (Step 1 regression)
  local tail_guard
  tail_guard=$(grep -c 'rerun_phase2.*| tail -1' \
    "${script_dir}/multi_linter.sh" || true)
  if [[ "${tail_guard}" -ge 1 ]]; then
    echo "PASS rerun_phase2_tail_guard: | tail -1 present on rerun_phase2 call"
    passed=$((passed + 1))
  else
    echo "FAIL rerun_phase2_tail_guard: | tail -1 missing from rerun_phase2 call"
    failed=$((failed + 1))
  fi

  # Feedback JSON: Python (ruff F841 — unused variable)
  test_stderr_json "feedback_json_python" \
    "${temp_dir}/feedback_test.py" \
    '"""Module."""


def foo():
    """Do nothing."""
    x = 1
    return 42' \
    _check_hook_json

  # Unified schema: Python ruff violations must have line/column keys
  # (not raw location.row/location.column from ruff JSON)
  # shellcheck disable=SC2329  # invoked indirectly as callback
  _check_ruff_unified() {
    local stderr="$1" exit_code="$2"
    [[ "${exit_code}" -ne 2 ]] && return 1
    local last_hook_info
    last_hook_info=$(echo "${stderr}" | grep -n '^\[hook\] ' | tail -1)
    [[ -z "${last_hook_info}" ]] && return 1
    local line_num="${last_hook_info%%:*}"
    local json_part
    json_part=$(echo "${stderr}" | tail -n +"${line_num}")
    json_part="${json_part#\[hook\] }"
    # Check all 5 unified schema keys on every element
    local valid
    valid=$(echo "${json_part}" | jaq '[.[] |
      has("line") and has("column") and has("code")
      and has("message") and has("linter")] | all' 2>/dev/null)
    [[ "${valid}" != "true" ]] && return 1
    return 0
  }
  test_stderr_json "ruff_unified_schema" \
    "${temp_dir}/feedback_test.py" \
    '"""Module."""


def foo():
    """Do nothing."""
    x = 1
    return 42' \
    _check_ruff_unified

  # Feedback JSON: Shell (SC2034 + SC2154 + SC2086)
  # shellcheck disable=SC2016  # intentional fixture content
  test_stderr_json "feedback_json_shell" \
    "${temp_dir}/feedback_test.sh" \
    '#!/bin/bash
unused="x"
echo $y' \
    _check_hook_json

  # Feedback JSON: JSON syntax error
  test_stderr_json "feedback_json_json" \
    "${temp_dir}/feedback_test.json" \
    '{invalid}' \
    _check_hook_json

  # Feedback JSON: YAML (gated on yamllint)
  if command -v yamllint >/dev/null 2>&1; then
    test_stderr_json "feedback_json_yaml" \
      "${temp_dir}/feedback_test.yaml" \
      'key: value
 bad_indent: true' \
      _check_hook_json
  else
    echo "[skip] feedback_json_yaml: yamllint not installed"
  fi

  # Feedback JSON: Dockerfile (gated on hadolint)
  if command -v hadolint >/dev/null 2>&1; then
    test_stderr_json "feedback_json_dockerfile" \
      "${temp_dir}/feedback_test.dockerfile" \
      'FROM ubuntu
RUN apt-get update' \
      _check_hook_json
  else
    echo "[skip] feedback_json_dockerfile: hadolint not installed"
  fi

  # Feedback JSON: TOML (gated on taplo)
  # taplo respects taplo.toml include patterns; /tmp files are outside
  # the include glob. Place fixture in project tree with cleanup.
  if command -v taplo >/dev/null 2>&1; then
    # taplo resolves include globs relative to CWD (project root), so the
    # fixture must be inside the project tree. Cleanup is EXIT-trapped.
    local toml_fixture="${project_dir}/test_fixture_broken.toml"
    printf '[broken\nkey = "value"\n' >"${toml_fixture}"
    test_stderr_json "feedback_json_toml" \
      "${toml_fixture}" \
      '[broken
key = "value"' \
      _check_hook_json
  else
    echo "[skip] feedback_json_toml: taplo not installed"
  fi

  # Feedback JSON: Markdown (gated on markdownlint-cli2)
  # Use 201 'x' chars to trigger MD013 (line length, not auto-fixable)
  if command -v markdownlint-cli2 >/dev/null 2>&1; then
    local md_fixture="${temp_dir}/feedback_test.md"
    printf 'x%.0s' {1..201} >"${md_fixture}"
    printf '\n' >>"${md_fixture}"
    local md_json='{"tool_input": {"file_path": "'"${md_fixture}"'"}}'
    set +e
    local md_stderr
    md_stderr=$(echo "${md_json}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${fixture_project_dir}" \
      "${script_dir}/multi_linter.sh" 2>&1 >/dev/null)
    local md_exit=$?
    set -e
    # shellcheck disable=SC2310  # intentional: checking exit in if
    if _check_hook_json "${md_stderr}" "${md_exit}"; then
      echo "PASS feedback_json_markdown"
      passed=$((passed + 1))
    else
      echo "FAIL feedback_json_markdown"
      echo "   exit=${md_exit}"
      echo "   stderr: ${md_stderr:0:200}"
      failed=$((failed + 1))
    fi
    # Markdown single [hook] line: stderr should have exactly 1 [hook] prefix
    # (the JSON payload only, no debug summary line)
    local hook_line_count
    hook_line_count=$(echo "${md_stderr}" | grep -c '^\[hook\] ' || true)
    if [[ "${hook_line_count}" -eq 1 ]]; then
      echo "PASS markdown_single_hook_line: 1 [hook] line (no debug summary)"
      passed=$((passed + 1))
    else
      echo "FAIL markdown_single_hook_line: ${hook_line_count} [hook] lines (expected 1)"
      failed=$((failed + 1))
    fi
  else
    echo "[skip] feedback_json_markdown: markdownlint-cli2 not installed"
    echo "[skip] markdown_single_hook_line: markdownlint-cli2 not installed"
  fi

  # Feedback JSON: TypeScript (gated on biome, uses ts_project_dir)
  if [[ -n "${biome_cmd:-}" ]]; then
    local ts_feedback_file="${temp_dir}/feedback_test.ts"
    echo 'const unused = "x";
console.log("test");' >"${ts_feedback_file}"
    local ts_json='{"tool_input": {"file_path": "'"${ts_feedback_file}"'"}}'
    set +e
    local ts_stderr
    ts_stderr=$(echo "${ts_json}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${ts_project_dir}" \
      "${script_dir}/multi_linter.sh" 2>&1 >/dev/null)
    local ts_exit=$?
    set -e
    # shellcheck disable=SC2310  # intentional: checking exit in if
    if _check_hook_json "${ts_stderr}" "${ts_exit}"; then
      echo "PASS feedback_json_typescript"
      passed=$((passed + 1))
    else
      echo "FAIL feedback_json_typescript"
      echo "   exit=${ts_exit}"
      echo "   stderr: ${ts_stderr:0:200}"
      failed=$((failed + 1))
    fi
  else
    echo "[skip] feedback_json_typescript: biome not installed"
  fi

  # Violation count: Shell (must have >= 2 violations)
  local shell_count_input='{"tool_input": {"file_path": "'"${temp_dir}/feedback_test.sh"'"}}'
  set +e
  local shell_count_stderr
  shell_count_stderr=$(echo "${shell_count_input}" | HOOK_SKIP_SUBPROCESS=1 \
    CLAUDE_PROJECT_DIR="${fixture_project_dir}" \
    "${script_dir}/multi_linter.sh" 2>&1 >/dev/null)
  set -e
  local shell_hook_info
  shell_hook_info=$(echo "${shell_count_stderr}" | grep -n '^\[hook\] ' | tail -1)
  local shell_line_num="${shell_hook_info%%:*}"
  local shell_json_extract=""
  if [[ -n "${shell_line_num}" ]]; then
    shell_json_extract=$(echo "${shell_count_stderr}" | tail -n +"${shell_line_num}")
    shell_json_extract="${shell_json_extract#\[hook\] }"
  fi
  local shell_count
  shell_count=$(echo "${shell_json_extract}" | jaq 'length' 2>/dev/null || echo "0")
  if [[ "${shell_count}" -ge 2 ]]; then
    echo "PASS feedback_count_shell: ${shell_count} violations (>= 2)"
    passed=$((passed + 1))
  else
    echo "FAIL feedback_count_shell: ${shell_count} violations (expected >= 2)"
    failed=$((failed + 1))
  fi

  echo ""
  echo "--- ShellCheck Compliance Tests ---"

  # Test: all hook scripts pass shellcheck
  if command -v shellcheck >/dev/null 2>&1; then
    local sc_ok=true
    for sc_file in "${script_dir}/multi_linter.sh" \
                   "${script_dir}/protect_linter_configs.sh" \
                   "${script_dir}/enforce_package_managers.sh" \
                   "${script_dir}/stop_config_guardian.sh" \
                   "${script_dir}/approve_configs.sh" \
                   "${script_dir}/test_hook.sh" \
                   "${script_dir}/../tests/hooks/test_subprocess_permissions.sh"; do
      if [[ -f "${sc_file}" ]]; then
        # shellcheck disable=SC2310  # intentional: checking in if
        if ! shellcheck "${sc_file}" >/dev/null 2>&1; then
          echo "FAIL shellcheck_compliance: $(basename "${sc_file}")"
          sc_ok=false
          failed=$((failed + 1))
        fi
      fi
    done
    if [[ "${sc_ok}" == "true" ]]; then
      echo "PASS shellcheck_compliance: all hook scripts clean"
      passed=$((passed + 1))
    fi
  else
    echo "SKIP shellcheck_compliance: shellcheck not installed"
  fi

  # Summary
  echo ""
  echo "=== Summary ==="
  echo "Passed: ${passed}"
  echo "Failed: ${failed}"

  if [[ "${failed}" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

file_path="${1:-}"

if [[ "${file_path}" == "--self-test" ]]; then
  run_self_test
fi

if [[ -z "${file_path}" ]]; then
  echo "Usage: $0 <file_path>"
  echo "       $0 --self-test    # Run comprehensive test suite"
  echo ""
  echo "Examples:"
  echo "  $0 ./my_script.sh      # Test shell linting"
  echo "  $0 ./config.yaml       # Test YAML linting"
  echo "  $0 ./main.py           # Test Python complexity"
  echo "  $0 ./Dockerfile        # Test Dockerfile linting"
  echo "  $0 ./app.dockerfile    # Test *.dockerfile extension"
  echo ""
  echo "Exit codes:"
  echo "  0 - No issues or warnings only (not fed to Claude)"
  echo "  2 - Blocking errors found (fed to Claude via stderr)"
  exit 1
fi

if [[ ! -f "${file_path}" ]]; then
  echo "Error: File not found: ${file_path}"
  exit 1
fi

# Construct JSON input like Claude Code does
json_input=$(
  cat <<EOF
{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "$(realpath "${file_path}" || true)"
  }
}
EOF
)

echo "=== Testing multi_linter.sh ==="
echo "Input file: ${file_path}"
echo "JSON input: ${json_input}"
echo ""
echo "=== Hook Output ==="

# Run the hook and capture exit code
script_dir="$(dirname "$(realpath "$0" || true)")"
set +e
echo "${json_input}" | "${script_dir}/multi_linter.sh"
exit_code=$?
set -e

echo ""
echo "=== Result ==="
echo "Exit code: ${exit_code}"
case ${exit_code} in
  0) echo "Status: OK (warnings only, not fed to Claude)" ;;
  2) echo "Status: BLOCKING (errors found, fed to Claude)" ;;
  *) echo "Status: UNKNOWN (exit code ${exit_code})" ;;
esac
