#!/bin/bash
# test_five_channels.sh - Test the five PostToolUse output channels from the spec matrix
#
# Tests the five distinct PostToolUse hook output channels documented in
# docs/specs/posttooluse-issue/posttoolusewrite-hook-stderr-silent-drop.md
# (Summary: Five-Channel Test Matrix).
#
# Part 1 (default): Automated tests that run each channel's hook script directly
#   and verify exit code, output stream, and content.
#
# Part 2 (--runbook): Prints step-by-step mitmproxy instructions for testing
#   each channel through Claude Code to observe system-reminder delivery.
#
# Usage:
#   bash .claude/tests/hooks/test_five_channels.sh           # automated tests
#   bash .claude/tests/hooks/test_five_channels.sh --runbook  # mitmproxy runbook

set -euo pipefail

# --- Path resolution ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Mode selection ---
mode="auto"
if [[ "${1:-}" == "--runbook" ]]; then
  mode="runbook"
fi

# =============================================================================
# Part 2: Mitmproxy Runbook
# =============================================================================

print_runbook() {
  local swap_settings="${script_dir}/swap_settings.sh"

  cat <<'RUNBOOK_HEADER'
================================================================================
  MITMPROXY RUNBOOK: Five-Channel PostToolUse system-reminder Verification
================================================================================

PREREQUISITE:
  In a separate terminal, start mitmproxy:

    mitmweb --listen-port 8080

  This opens a web UI at http://127.0.0.1:8081 for inspecting API requests.

SETTINGS HELPER:
  Use swap_settings.sh to backup/restore your .claude/settings.json:

RUNBOOK_HEADER
  printf "    bash %s backup        # before testing\n" "${swap_settings}"
  printf "    bash %s restore       # after testing\n\n" "${swap_settings}"

  # --- Channel 1 ---
  cat <<'CH1'
--------------------------------------------------------------------------------
CHANNEL 1: stderr + exit 2
--------------------------------------------------------------------------------
  Expected system-reminder: YES (confirmed by mitmproxy on 2026-02-21)

  1. Create the hook script at /tmp/hook-channel-1.sh:

       #!/bin/bash
       echo "[channel-1] test message with exit 2" >&2
       exit 2

     Make executable:  chmod +x /tmp/hook-channel-1.sh

  2. Write this to .claude/settings.json:

       {
         "hooks": {
           "PostToolUse": [
             {
               "matcher": "Write",
               "hooks": [
                 {
                   "type": "command",
                   "command": "/tmp/hook-channel-1.sh",
                   "timeout": 5
                 }
               ]
             }
           ]
         },
         "disableAllHooks": false
       }

  3. Launch Claude Code with mitmproxy:

       HTTPS_PROXY=http://localhost:8080 claude --debug hooks

  4. Paste this prompt:

       Write this to /tmp/test.txt: hello world

  5. In mitmweb (http://127.0.0.1:8081):
     - Find the API request to api.anthropic.com
     - Search the request body for "channel-1"
     - Look for a <system-reminder> text block containing "channel-1"

  6. Expected result:
     stderr content SHOULD appear in a <system-reminder> text block.
     This channel is CONFIRMED working (mitmproxy evidence from 2026-02-21).

CH1

  # --- Channel 2 ---
  cat <<'CH2'
--------------------------------------------------------------------------------
CHANNEL 2: stderr + exit 1
--------------------------------------------------------------------------------
  Expected system-reminder: UNTESTED

  1. Create the hook script at /tmp/hook-channel-2.sh:

       #!/bin/bash
       echo "[channel-2] test message with exit 1" >&2
       exit 1

     Make executable:  chmod +x /tmp/hook-channel-2.sh

  2. Write this to .claude/settings.json:

       {
         "hooks": {
           "PostToolUse": [
             {
               "matcher": "Write",
               "hooks": [
                 {
                   "type": "command",
                   "command": "/tmp/hook-channel-2.sh",
                   "timeout": 5
                 }
               ]
             }
           ]
         },
         "disableAllHooks": false
       }

  3. Launch Claude Code with mitmproxy:

       HTTPS_PROXY=http://localhost:8080 claude --debug hooks

  4. Paste this prompt:

       Write this to /tmp/test.txt: hello world

  5. In mitmweb (http://127.0.0.1:8081):
     - Find the API request to api.anthropic.com
     - Search the request body for "channel-2"
     - Look for a <system-reminder> text block containing "channel-2"

  6. Expected result:
     UNKNOWN. Exit 1 is "fatal error" for PostToolUse hooks.
     Investigation A3 found exit 1 tool_result identical to exit 2,
     but system-reminder delivery was never tested with mitmproxy.

CH2

  # --- Channel 3 ---
  cat <<'CH3'
--------------------------------------------------------------------------------
CHANNEL 3: JSON stdout + exit 2
--------------------------------------------------------------------------------
  Expected system-reminder: UNTESTED

  1. Create the hook script at /tmp/hook-channel-3.sh:

       #!/bin/bash
       echo '{"decision":"block","reason":"channel-3 test"}'
       exit 2

     Make executable:  chmod +x /tmp/hook-channel-3.sh

  2. Write this to .claude/settings.json:

       {
         "hooks": {
           "PostToolUse": [
             {
               "matcher": "Write",
               "hooks": [
                 {
                   "type": "command",
                   "command": "/tmp/hook-channel-3.sh",
                   "timeout": 5
                 }
               ]
             }
           ]
         },
         "disableAllHooks": false
       }

  3. Launch Claude Code with mitmproxy:

       HTTPS_PROXY=http://localhost:8080 claude --debug hooks

  4. Paste this prompt:

       Write this to /tmp/test.txt: hello world

  5. In mitmweb (http://127.0.0.1:8081):
     - Find the API request to api.anthropic.com
     - Search the request body for "channel-3"
     - Look for a <system-reminder> text block containing "channel-3"
     - Also check if the JSON decision/reason fields appear anywhere

  6. Expected result:
     UNKNOWN. Investigation B1 showed JSON IS parsed by CC ("not async,
     continuing normal processing") but then discarded from tool_result.
     Whether the parsed JSON produces a system-reminder block is untested.

CH3

  # --- Channel 4 ---
  cat <<'CH4'
--------------------------------------------------------------------------------
CHANNEL 4: JSON stdout + exit 0
--------------------------------------------------------------------------------
  Expected system-reminder: UNTESTED

  1. Create the hook script at /tmp/hook-channel-4.sh:

       #!/bin/bash
       echo '{"decision":"approve"}'
       exit 0

     Make executable:  chmod +x /tmp/hook-channel-4.sh

  2. Write this to .claude/settings.json:

       {
         "hooks": {
           "PostToolUse": [
             {
               "matcher": "Write",
               "hooks": [
                 {
                   "type": "command",
                   "command": "/tmp/hook-channel-4.sh",
                   "timeout": 5
                 }
               ]
             }
           ]
         },
         "disableAllHooks": false
       }

  3. Launch Claude Code with mitmproxy:

       HTTPS_PROXY=http://localhost:8080 claude --debug hooks

  4. Paste this prompt:

       Write this to /tmp/test.txt: hello world

  5. In mitmweb (http://127.0.0.1:8081):
     - Find the API request to api.anthropic.com
     - Search the request body for "channel-4" or "approve"
     - Check if ANY system-reminder text block is present for this hook

  6. Expected result:
     UNKNOWN. Exit 0 with JSON stdout is the "success with structured
     output" path. Investigation A2 confirmed decision:block with exit 0
     was silently dropped from tool_result. Whether exit 0 produces
     ANY system-reminder block (even for approve) is untested.
     Likely result: NO system-reminder (exit 0 = success = silent).

CH4

  # --- Channel 5 ---
  cat <<'CH5'
--------------------------------------------------------------------------------
CHANNEL 5: stderr + exit 0
--------------------------------------------------------------------------------
  Expected system-reminder: UNTESTED

  1. Create the hook script at /tmp/hook-channel-5.sh:

       #!/bin/bash
       echo "[channel-5] test message with exit 0" >&2
       exit 0

     Make executable:  chmod +x /tmp/hook-channel-5.sh

  2. Write this to .claude/settings.json:

       {
         "hooks": {
           "PostToolUse": [
             {
               "matcher": "Write",
               "hooks": [
                 {
                   "type": "command",
                   "command": "/tmp/hook-channel-5.sh",
                   "timeout": 5
                 }
               ]
             }
           ]
         },
         "disableAllHooks": false
       }

  3. Launch Claude Code with mitmproxy:

       HTTPS_PROXY=http://localhost:8080 claude --debug hooks

  4. Paste this prompt:

       Write this to /tmp/test.txt: hello world

  5. In mitmweb (http://127.0.0.1:8081):
     - Find the API request to api.anthropic.com
     - Search the request body for "channel-5"
     - Check if ANY system-reminder text block is present for this hook

  6. Expected result:
     UNKNOWN. This is the "success with advisory stderr" path (e.g.,
     hook:warning messages on subprocess timeout followed by clean
     rerun). Only stderr+exit2 was mitmproxy-verified. Whether exit 0
     with stderr produces a system-reminder is the key open question
     for advisory messages.

CH5

  # --- Cleanup reminder ---
  cat <<'CLEANUP_HEAD'
--------------------------------------------------------------------------------
CLEANUP
--------------------------------------------------------------------------------
  After testing all channels:

CLEANUP_HEAD
  printf "    bash %s restore\n" "${swap_settings}"
  cat <<'CLEANUP_TAIL'
    rm -f /tmp/hook-channel-{1,2,3,4,5}.sh
    rm -f /tmp/test.txt

  Record results in the Five-Channel Test Matrix table in:
    docs/specs/posttooluse-issue/posttoolusewrite-hook-stderr-silent-drop.md

================================================================================
CLEANUP_TAIL
}

# =============================================================================
# Part 1: Automated Tests
# =============================================================================

run_automated_tests() {
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

  # --- Create the 5 channel hook scripts ---

  # Channel 1: stderr + exit 2
  cat >"${tmp_dir}/hook-channel-1.sh" <<'HOOK1'
#!/bin/bash
echo "[channel-1] test message with exit 2" >&2
exit 2
HOOK1
  chmod +x "${tmp_dir}/hook-channel-1.sh"

  # Channel 2: stderr + exit 1
  cat >"${tmp_dir}/hook-channel-2.sh" <<'HOOK2'
#!/bin/bash
echo "[channel-2] test message with exit 1" >&2
exit 1
HOOK2
  chmod +x "${tmp_dir}/hook-channel-2.sh"

  # Channel 3: JSON stdout + exit 2
  cat >"${tmp_dir}/hook-channel-3.sh" <<'HOOK3'
#!/bin/bash
echo '{"decision":"block","reason":"channel-3 test"}'
exit 2
HOOK3
  chmod +x "${tmp_dir}/hook-channel-3.sh"

  # Channel 4: JSON stdout + exit 0
  cat >"${tmp_dir}/hook-channel-4.sh" <<'HOOK4'
#!/bin/bash
echo '{"decision":"approve"}'
exit 0
HOOK4
  chmod +x "${tmp_dir}/hook-channel-4.sh"

  # Channel 5: stderr + exit 0
  cat >"${tmp_dir}/hook-channel-5.sh" <<'HOOK5'
#!/bin/bash
echo "[channel-5] test message with exit 0" >&2
exit 0
HOOK5
  chmod +x "${tmp_dir}/hook-channel-5.sh"

  # === Begin tests ===
  printf "=== Five-Channel PostToolUse Hook Tests ===\n"

  # -----------------------------------------------------------------------
  # Channel 1: stderr + exit 2
  # -----------------------------------------------------------------------
  printf "\n--- Channel 1: stderr + exit 2 ---\n"

  local stdout_1="" stderr_1="" exit_1=0
  stdout_1=$("${tmp_dir}/hook-channel-1.sh" 2>"${tmp_dir}/stderr-1.txt") \
    || exit_1=$?
  stderr_1=$(cat "${tmp_dir}/stderr-1.txt")

  assert "ch1_exit" "[[ ${exit_1} -eq 2 ]]" \
    "exit code 2" "exit code ${exit_1} (expected 2)"

  assert "ch1_stderr_content" "[[ '${stderr_1}' == *'channel-1'* ]]" \
    "stderr contains 'channel-1'" "stderr missing 'channel-1': ${stderr_1}"

  assert "ch1_stderr_message" "[[ '${stderr_1}' == *'test message with exit 2'* ]]" \
    "stderr has expected message" "stderr message mismatch: ${stderr_1}"

  assert "ch1_stdout_empty" "[[ -z '${stdout_1}' ]]" \
    "stdout is empty" "stdout should be empty but got: ${stdout_1}"

  # -----------------------------------------------------------------------
  # Channel 2: stderr + exit 1
  # -----------------------------------------------------------------------
  printf "\n--- Channel 2: stderr + exit 1 ---\n"

  local stdout_2="" stderr_2="" exit_2=0
  stdout_2=$("${tmp_dir}/hook-channel-2.sh" 2>"${tmp_dir}/stderr-2.txt") \
    || exit_2=$?
  stderr_2=$(cat "${tmp_dir}/stderr-2.txt")

  assert "ch2_exit" "[[ ${exit_2} -eq 1 ]]" \
    "exit code 1" "exit code ${exit_2} (expected 1)"

  assert "ch2_stderr_content" "[[ '${stderr_2}' == *'channel-2'* ]]" \
    "stderr contains 'channel-2'" "stderr missing 'channel-2': ${stderr_2}"

  assert "ch2_stderr_message" "[[ '${stderr_2}' == *'test message with exit 1'* ]]" \
    "stderr has expected message" "stderr message mismatch: ${stderr_2}"

  assert "ch2_stdout_empty" "[[ -z '${stdout_2}' ]]" \
    "stdout is empty" "stdout should be empty but got: ${stdout_2}"

  # -----------------------------------------------------------------------
  # Channel 3: JSON stdout + exit 2
  # -----------------------------------------------------------------------
  printf "\n--- Channel 3: JSON stdout + exit 2 ---\n"

  local stdout_3="" stderr_3="" exit_3=0
  stdout_3=$("${tmp_dir}/hook-channel-3.sh" 2>"${tmp_dir}/stderr-3.txt") \
    || exit_3=$?
  stderr_3=$(cat "${tmp_dir}/stderr-3.txt")

  assert "ch3_exit" "[[ ${exit_3} -eq 2 ]]" \
    "exit code 2" "exit code ${exit_3} (expected 2)"

  assert "ch3_stdout_json" "[[ '${stdout_3}' == *'decision'* ]]" \
    "stdout contains JSON with 'decision'" "stdout missing JSON: ${stdout_3}"

  assert "ch3_stdout_reason" "[[ '${stdout_3}' == *'channel-3 test'* ]]" \
    "stdout JSON has 'channel-3 test' reason" "stdout reason mismatch: ${stdout_3}"

  assert "ch3_stderr_empty" "[[ -z '${stderr_3}' ]]" \
    "stderr is empty" "stderr should be empty but got: ${stderr_3}"

  # -----------------------------------------------------------------------
  # Channel 4: JSON stdout + exit 0
  # -----------------------------------------------------------------------
  printf "\n--- Channel 4: JSON stdout + exit 0 ---\n"

  local stdout_4="" stderr_4="" exit_4=0
  stdout_4=$("${tmp_dir}/hook-channel-4.sh" 2>"${tmp_dir}/stderr-4.txt") \
    || exit_4=$?
  stderr_4=$(cat "${tmp_dir}/stderr-4.txt")

  assert "ch4_exit" "[[ ${exit_4} -eq 0 ]]" \
    "exit code 0" "exit code ${exit_4} (expected 0)"

  assert "ch4_stdout_json" "[[ '${stdout_4}' == *'decision'* ]]" \
    "stdout contains JSON with 'decision'" "stdout missing JSON: ${stdout_4}"

  assert "ch4_stdout_approve" "[[ '${stdout_4}' == *'approve'* ]]" \
    "stdout JSON has 'approve' decision" "stdout decision mismatch: ${stdout_4}"

  assert "ch4_stderr_empty" "[[ -z '${stderr_4}' ]]" \
    "stderr is empty" "stderr should be empty but got: ${stderr_4}"

  # -----------------------------------------------------------------------
  # Channel 5: stderr + exit 0
  # -----------------------------------------------------------------------
  printf "\n--- Channel 5: stderr + exit 0 ---\n"

  local stdout_5="" stderr_5="" exit_5=0
  stdout_5=$("${tmp_dir}/hook-channel-5.sh" 2>"${tmp_dir}/stderr-5.txt") \
    || exit_5=$?
  stderr_5=$(cat "${tmp_dir}/stderr-5.txt")

  assert "ch5_exit" "[[ ${exit_5} -eq 0 ]]" \
    "exit code 0" "exit code ${exit_5} (expected 0)"

  assert "ch5_stderr_content" "[[ '${stderr_5}' == *'channel-5'* ]]" \
    "stderr contains 'channel-5'" "stderr missing 'channel-5': ${stderr_5}"

  assert "ch5_stderr_message" "[[ '${stderr_5}' == *'test message with exit 0'* ]]" \
    "stderr has expected message" "stderr message mismatch: ${stderr_5}"

  assert "ch5_stdout_empty" "[[ -z '${stdout_5}' ]]" \
    "stdout is empty" "stdout should be empty but got: ${stdout_5}"

  # === Summary ===
  printf "\n=== Summary ===\n"
  printf "Passed: %d\nFailed: %d\n" "${passed}" "${failed}"
  printf "Total:  %d checks across 5 channels\n" "$((passed + failed))"
  [[ "${failed}" -gt 0 ]] && exit 1
  exit 0
}

# =============================================================================
# Dispatch
# =============================================================================

case "${mode}" in
  runbook) print_runbook ;;
  auto) run_automated_tests ;;
  *)
    printf "Unknown mode: %s\n" "${mode}" >&2
    exit 1
    ;;
esac
