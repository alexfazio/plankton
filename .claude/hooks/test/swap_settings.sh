#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/../../.." && pwd)"
settings_file="${project_dir}/.claude/settings.json"
backup_file="${project_dir}/.claude/settings.json.backup"

cmd_backup() {
  if [[ -f "${backup_file}" ]]; then
    echo "ERROR: Backup already exists at ${backup_file}" >&2
    echo "Restore first before creating a new backup." >&2
    exit 1
  fi
  cp "${settings_file}" "${backup_file}"
  shasum -a 256 "${backup_file}" | cut -d' ' -f1 >"${backup_file}.sha256"
  echo "Backup created: ${backup_file}"
  echo "SHA256 stored:  ${backup_file}.sha256"
}

cmd_swap_minimal() {
  if [[ ! -f "${backup_file}" ]]; then
    echo "ERROR: No backup found. Run 'backup' first." >&2
    exit 1
  fi
  cat <<'EOF' >"${settings_file}"
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/test/minimal-test-hook.sh",
            "timeout": 5
          }
        ]
      }
    ]
  },
  "disableAllHooks": false
}
EOF
  echo "Settings swapped to minimal hook."
  echo "Active hook: .claude/hooks/test/minimal-test-hook.sh"
}

cmd_restore() {
  if [[ ! -f "${backup_file}" ]]; then
    echo "ERROR: No backup found at ${backup_file}" >&2
    exit 1
  fi
  if [[ -f "${backup_file}.sha256" ]]; then
    stored_sha256="$(cat "${backup_file}.sha256")"
    current_sha256="$(shasum -a 256 "${backup_file}" | cut -d' ' -f1)"
    if [[ "${stored_sha256}" != "${current_sha256}" ]]; then
      echo "WARNING: Backup SHA256 mismatch. File may have been modified." >&2
      echo "  Stored:  ${stored_sha256}" >&2
      echo "  Current: ${current_sha256}" >&2
    fi
  fi
  cp "${backup_file}" "${settings_file}"
  rm -f "${backup_file}" "${backup_file}.sha256"
  echo "Settings restored from backup."
}

cmd_status() {
  if [[ -f "${backup_file}" ]]; then
    if grep -q "minimal-test-hook" "${settings_file}" 2>/dev/null; then
      echo "Status: minimal"
    else
      echo "Status: unknown (backup exists but settings modified)"
    fi
  else
    echo "Status: original"
  fi

  if [[ -f "${settings_file}" ]]; then
    if command -v jaq >/dev/null 2>&1; then
      hook_cmd="$(jaq -r '.hooks.PostToolUse[0].hooks[0].command // empty' "${settings_file}" 2>/dev/null || true)"
    else
      hook_cmd=""
    fi
    if [[ -n "${hook_cmd}" ]]; then
      echo "PostToolUse hook: ${hook_cmd}"
    else
      echo "PostToolUse hook: (none found or not parseable)"
    fi
  else
    echo "Settings file not found."
  fi
}

usage() {
  echo "Usage: $(basename "$0") <command>"
  echo ""
  echo "Commands:"
  echo "  backup        Back up current settings.json"
  echo "  swap-minimal  Replace settings.json with minimal test hook"
  echo "  restore       Restore settings.json from backup"
  echo "  status        Show current settings state"
}

case "${1:-}" in
  backup) cmd_backup ;;
  swap-minimal) cmd_swap_minimal ;;
  restore) cmd_restore ;;
  status) cmd_status ;;
  *) usage ;;
esac
