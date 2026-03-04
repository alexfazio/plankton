#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${script_dir}/_run_canonical_hook_test.sh" "verify_feedback_loop.sh" "$@"
