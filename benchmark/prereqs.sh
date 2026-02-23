#!/usr/bin/env bash
# Plankton Benchmark — Phase 0 Prerequisites Checker
# Verifies all 8 prerequisites from the ADR before benchmark runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PASS=0
FAIL=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf "  PASS  %s\n" "${name}"
    ((PASS++))
  else
    printf "  FAIL  %s\n" "${name}"
    ((FAIL++))
  fi
}

check_output() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  output=$("$@" 2>&1) || true
  if echo "${output}" | grep -q "${expected}"; then
    printf "  PASS  %s\n" "${name}"
    ((PASS++))
  else
    printf "  FAIL  %s — expected '%s' in output\n" "${name}" "${expected}"
    ((FAIL++))
  fi
}

echo "=== Plankton Benchmark Prerequisites ==="
echo ""

# 1. Claude Code version
echo "[1/8] Claude Code version"
CC_VERSION=$(claude -v 2>/dev/null || echo "not found")
if [[ "${CC_VERSION}" != "not found" ]]; then
  printf "  PASS  claude -v = %s\n" "${CC_VERSION}"
  ((PASS++))
else
  printf "  FAIL  claude CLI not found\n"
  ((FAIL++))
fi

# 2. cc -bare alias (defined in ~/.zshrc, not available in bash)
echo "[2/8] cc -bare alias"
if grep -q "bare" "${HOME}/.zshrc" 2>/dev/null; then
  printf "  PASS  cc -bare defined in ~/.zshrc\n"
  ((PASS++))
else
  printf "  FAIL  cc -bare not found in ~/.zshrc\n"
  ((FAIL++))
fi

# 3. bare-settings.json
echo "[3/8] bare-settings.json"
BARE_SETTINGS="${HOME}/.claude/bare-settings.json"
if [[ -f "${BARE_SETTINGS}" ]]; then
  if grep -q '"disableAllHooks": true' "${BARE_SETTINGS}"; then
    printf "  PASS  %s contains disableAllHooks: true\n" "${BARE_SETTINGS}"
    ((PASS++))
  else
    printf "  FAIL  %s exists but missing disableAllHooks: true\n" "${BARE_SETTINGS}"
    ((FAIL++))
  fi
else
  printf "  FAIL  %s not found\n" "${BARE_SETTINGS}"
  ((FAIL++))
fi

# 4. Worktree support (lightweight check — just test the flag exists)
echo "[4/8] claude -p --worktree support"
if claude --help 2>&1 | grep -q "worktree"; then
  printf "  PASS  --worktree flag available\n"
  ((PASS++))
else
  printf "  FAIL  --worktree not found in claude --help\n"
  ((FAIL++))
fi

# 5. Baseline hook isolation (skipped in quick mode — requires running claude -p)
echo "[5/8] Baseline hook isolation"
printf "  SKIP  Run manually: cc -bare -p --output-format json 'echo test' and verify zero hook activity\n"

# 6. CLAUDE.md handling
echo "[6/8] CLAUDE.md status"
if [[ -f "${REPO_ROOT}/CLAUDE.md.bak" ]] && [[ ! -f "${REPO_ROOT}/CLAUDE.md" ]]; then
  printf "  PASS  CLAUDE.md renamed to CLAUDE.md.bak\n"
  ((PASS++))
elif [[ -f "${REPO_ROOT}/CLAUDE.md" ]]; then
  printf "  WARN  CLAUDE.md still present — rename to CLAUDE.md.bak before benchmark runs\n"
  printf "        Run: mv %s/CLAUDE.md %s/CLAUDE.md.bak\n" "${REPO_ROOT}" "${REPO_ROOT}"
  ((FAIL++))
else
  printf "  FAIL  Neither CLAUDE.md nor CLAUDE.md.bak found\n"
  ((FAIL++))
fi

# 7. EvalPlus installed (check venv first, then system python)
echo "[7/8] EvalPlus installation"
PYTHON="${REPO_ROOT}/.venv/bin/python"
if [[ ! -x "${PYTHON}" ]]; then
  PYTHON="python3"
fi
if "${PYTHON}" -c "import evalplus; print(f'evalplus {evalplus.__version__}')" 2>/dev/null; then
  printf "  PASS  evalplus installed\n"
  ((PASS++))
else
  printf "  FAIL  evalplus not installed — run: pip install evalplus\n"
  ((FAIL++))
fi

# 8. Results directory
echo "[8/8] Results directory"
RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "${RESULTS_DIR}/samples" "${RESULTS_DIR}/logs"
printf "  PASS  %s created\n" "${RESULTS_DIR}"
((PASS++))

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ ${FAIL} -gt 0 ]]; then
  echo "Fix failures before running the benchmark."
  exit 1
else
  echo "All prerequisites met. Ready for Phase 1."
fi
