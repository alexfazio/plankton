#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
canonical_name="${1:?missing canonical hook test name}"
shift

exec bash "${script_dir}/../../hooks/test/${canonical_name}" "$@"
