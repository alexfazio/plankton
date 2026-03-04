#!/usr/bin/env bash
# Run the non-benchmark Plankton hook-related test surface before push.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

for test_script in .claude/hooks/test/*.sh; do
  case "$(basename "${test_script}")" in
    _run_canonical_hook_test.sh | minimal-test-hook.sh | swap_settings.sh | test_empirical_p0.sh | test_empirical_p3_p4.sh)
      continue
      ;;
    *)
      bash "${test_script}"
      ;;
  esac
done

bash .claude/hooks/test_hook.sh --self-test
uv run pytest tests/integration/test_hooks_robustness.py -q
