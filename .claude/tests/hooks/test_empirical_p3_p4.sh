#!/bin/bash
# test_empirical_p3_p4.sh - Empirical tests: env propagation (P3) and model precedence (P4)
#
# P3: Does --settings env block propagate env vars to the subprocess?
# P4: Does --model flag override env.ANTHROPIC_MODEL from settings?
#
# Requires: claude binary on PATH, ANTHROPIC_API_KEY set, network access
#
# Usage: bash .claude/tests/hooks/test_empirical_p3_p4.sh

set -euo pipefail

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

# --- Gate: prerequisites ---
if ! command -v claude >/dev/null 2>&1; then
  printf "SKIP: claude binary not on PATH\n"
  exit 0
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  printf "SKIP: ANTHROPIC_API_KEY not set\n"
  exit 0
fi

# === Begin tests ===
printf "=== Empirical P3/P4: Env Propagation and Model Precedence ===\n"
printf "NOTE: These tests make live API calls (~30s each)\n\n"

# ============================================================================
# Test p3: --settings env block propagation
# ============================================================================
printf '\n%s\n' "--- p3: env block propagation via --settings ---"

# Create settings with a custom env var
p3_settings="${tmp_dir}/p3-settings.json"
cat >"${p3_settings}" <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true,
  "env": {
    "PLANKTON_P3_TEST_MARKER": "p3_propagation_confirmed"
  }
}
EOF

p3_output="${tmp_dir}/p3_stdout.txt"
p3_stderr="${tmp_dir}/p3_stderr.txt"
p3_exit=0
timeout 60 claude -p \
  "Use the Bash tool to run: echo \$PLANKTON_P3_TEST_MARKER — then reply with ONLY the output value. If empty, reply NOT_SET." \
  --dangerously-skip-permissions \
  --settings "${p3_settings}" \
  --disallowedTools "Edit,Write,WebFetch,WebSearch,NotebookEdit,Task,Glob,Grep" \
  --max-turns 3 \
  --model haiku \
  </dev/null >"${p3_output}" 2>"${p3_stderr}" || p3_exit=$?

printf "  exit code: %d\n" "${p3_exit}"
p3_out=$(cat "${p3_output}" 2>/dev/null || echo '(empty)')
printf "  stdout: %s\n" "${p3_out}"

assert "p3_env_propagated" \
  "grep -q 'p3_propagation_confirmed' '${p3_output}'" \
  "env var propagated: PLANKTON_P3_TEST_MARKER visible to subprocess" \
  "env var NOT propagated — --settings env block may not reach subprocess"

# --- P3 Answer ---
printf "\n--- P3 Empirical Answer ---\n"
if grep -q 'p3_propagation_confirmed' "${p3_output}" 2>/dev/null; then
  printf "CONFIRMED: --settings env block propagates env vars to the subprocess.\n"
  printf "Alternative provider routing via settings env works.\n"
elif grep -q 'NOT_SET' "${p3_output}" 2>/dev/null; then
  printf "NEGATIVE: --settings env block does NOT propagate to subprocess.\n"
  printf "Shell-level export is needed as a fallback for provider routing.\n"
else
  printf "INCONCLUSIVE: Could not determine propagation. Check output above.\n"
fi

# ============================================================================
# Test p4: --model flag vs env.ANTHROPIC_MODEL precedence
# ============================================================================
printf "\n--- p4: --model flag vs env.ANTHROPIC_MODEL precedence ---\n"

# Create settings that set ANTHROPIC_MODEL to opus
p4_settings="${tmp_dir}/p4-settings.json"
cat >"${p4_settings}" <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true,
  "env": {
    "ANTHROPIC_MODEL": "claude-opus-4-20250514"
  }
}
EOF

# Use a file-based approach: ask the model to identify itself
p4_output="${tmp_dir}/p4_stdout.txt"
p4_stderr="${tmp_dir}/p4_stderr.txt"
p4_exit=0
timeout 60 claude -p \
  "What is your exact model ID? Reply with ONLY the model identifier string, nothing else." \
  --dangerously-skip-permissions \
  --settings "${p4_settings}" \
  --disallowedTools "Edit,Write,Bash,WebFetch,WebSearch,NotebookEdit,Task,Glob,Grep" \
  --max-turns 1 \
  --model haiku \
  </dev/null >"${p4_output}" 2>"${p4_stderr}" || p4_exit=$?

printf "  exit code: %d\n" "${p4_exit}"
p4_out=$(cat "${p4_output}" 2>/dev/null || echo '(empty)')
printf "  stdout: %s\n" "${p4_out}"

# Check if the response mentions haiku (--model flag won) or opus (env won)
p4_answer="inconclusive"
if grep -qi 'haiku' "${p4_output}" 2>/dev/null; then
  p4_answer="flag_wins"
elif grep -qi 'opus' "${p4_output}" 2>/dev/null; then
  p4_answer="env_wins"
fi

assert "p4_precedence_determined" \
  "[[ '${p4_answer}' != 'inconclusive' ]]" \
  "model precedence determined: ${p4_answer}" \
  "could not determine which takes precedence — check output above"

# --- P4 Answer ---
printf "\n--- P4 Empirical Answer ---\n"
case "${p4_answer}" in
  flag_wins)
    printf "CONFIRMED: --model flag takes precedence over env.ANTHROPIC_MODEL.\n"
    printf "Per-tier model selection via --model works even with provider env routing.\n"
    ;;
  env_wins)
    printf "CONFIRMED: env.ANTHROPIC_MODEL takes precedence over --model flag.\n"
    printf "WARNING: Per-tier model selection may be overridden by settings env.\n"
    printf "Avoid setting ANTHROPIC_MODEL in subprocess settings when using tier models.\n"
    ;;
  *)
    printf "INCONCLUSIVE: Could not determine precedence. Check output above.\n"
    ;;
esac

# ============================================================================
# Test v10: Z.AI provider routing via settings env block
# ============================================================================
printf '\n%s\n' "--- v10: Z.AI provider routing via --settings env ---"

if [[ -z "${ZAI_API_KEY:-}" ]]; then
  printf "  SKIP v10: ZAI_API_KEY not set\n"
else
  v10_settings="${tmp_dir}/v10-zai-settings.json"
  cat >"${v10_settings}" <<ZAIEOF
{
  "\$schema": "https://json.schemastore.org/claude-code-settings.json",
  "disableAllHooks": true,
  "skipDangerousModePermissionPrompt": true,
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "${ZAI_API_KEY}",
    "ANTHROPIC_MODEL": "glm-4.5-air",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-4.7",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-4.5-air",
    "API_TIMEOUT_MS": "60000"
  }
}
ZAIEOF

  v10_output="${tmp_dir}/v10_stdout.txt"
  v10_stderr="${tmp_dir}/v10_stderr.txt"
  v10_exit=0
  timeout 60 claude -p \
    "What is your exact model name or ID? Reply with ONLY the model identifier, nothing else." \
    --dangerously-skip-permissions \
    --settings "${v10_settings}" \
    --disallowedTools "Edit,Write,Bash,WebFetch,WebSearch,NotebookEdit,Task,Glob,Grep" \
    --max-turns 3 \
    --model haiku \
    </dev/null >"${v10_output}" 2>"${v10_stderr}" || v10_exit=$?

  printf "  exit code: %d\n" "${v10_exit}"
  v10_out=$(cat "${v10_output}" 2>/dev/null || echo '(empty)')
  printf "  stdout: %s\n" "${v10_out}"

  # GLM models typically self-identify with "glm" in the response
  assert "v10_zai_routed" \
    "[[ ${v10_exit} -eq 0 ]]" \
    "Z.AI routing succeeded (exit 0, response: ${v10_out})" \
    "Z.AI routing failed (exit ${v10_exit})"

  # Check if model alias resolved — --model haiku should map to glm-4.5-air
  if grep -qi 'glm' "${v10_output}" 2>/dev/null; then
    printf "  V10 detail: model self-identifies as GLM — alias resolved correctly\n"
  else
    printf "  V10 detail: model response does not mention GLM — alias may not resolve\n"
  fi

  printf "\n--- Diagnostic: v10 stderr (last 10 lines) ---\n"
  tail -10 "${v10_stderr}" 2>/dev/null || printf "(empty)\n"
fi

# --- Diagnostic output ---
printf "\n--- Diagnostic: p3 stderr (last 10 lines) ---\n"
tail -10 "${p3_stderr}" 2>/dev/null || printf "(empty)\n"
printf "\n--- Diagnostic: p4 stderr (last 10 lines) ---\n"
tail -10 "${p4_stderr}" 2>/dev/null || printf "(empty)\n"

# === Summary ===
printf "\n=== Summary ===\n"
printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
[[ "${failed}" -gt 0 ]] && exit 1
exit 0
