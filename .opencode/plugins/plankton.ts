import type { Plugin } from "@opencode-ai/plugin";
import { execSync } from "child_process";
import * as path from "path";

/**
 * Plankton plugin for OpenCode.
 *
 * Wraps the same bash hook scripts used by the Claude Code and Pi adapters
 * (.claude/hooks/*) so all three agents share a single linting backend.
 *
 * Hooks wired:
 *   tool.execute.before  - config protection + package-manager enforcement
 *   tool.execute.after   - multi-linter (format, lint, delegate)
 */
export const PlanktonPlugin: Plugin = async ({ directory }) => {
  const hooksDir = path.join(directory, ".claude", "hooks");

  const baseEnv: Record<string, string> = {
    ...Object.fromEntries(
      Object.entries(process.env).filter(
        (entry): entry is [string, string] => entry[1] !== undefined,
      ),
    ),
    PLANKTON_PROJECT_DIR: directory,
    PLANKTON_DELEGATE_CMD: "opencode",
    PLANKTON_PROTECTED_DIRS: ".claude:.plankton:.opencode",
  };

  // opencode tool names that modify files on disk
  const fileTools = new Set(["write", "edit", "patch", "multiedit"]);

  // map opencode lowercase tool names to the names the bash hooks expect
  const toolNameMap: Record<string, string> = {
    write: "Write",
    edit: "Edit",
    patch: "Write",
    multiedit: "Edit",
    bash: "Bash",
  };

  /**
   * Extract the file path from opencode tool args.
   * opencode uses camelCase (`filePath`); the bash hooks expect snake_case.
   */
  function extractFilePath(args: Record<string, unknown>): string | undefined {
    if (!args) return undefined;
    const fp = args.filePath ?? args.file_path ?? args.path;
    return typeof fp === "string" ? fp : undefined;
  }

  /**
   * Run a pre-tool hook script synchronously.
   * Returns the parsed JSON result or a fail-open approve on any error.
   */
  function runPreHook(
    script: string,
    input: string,
  ): { decision: string; reason?: string } {
    try {
      const stdout = execSync(`bash "${path.join(hooksDir, script)}"`, {
        input,
        env: baseEnv,
        timeout: 5_000,
        encoding: "utf-8",
        stdio: ["pipe", "pipe", "pipe"],
      });
      return JSON.parse(stdout.trim());
    } catch {
      return { decision: "approve" };
    }
  }

  return {
    // ---- PreToolUse --------------------------------------------------------
    "tool.execute.before": async (input, output) => {
      const tool = input.tool;

      // Config protection (Edit / Write / Patch)
      if (fileTools.has(tool)) {
        const fp = extractFilePath(output.args);
        if (fp) {
          const result = runPreHook(
            "protect_linter_configs.sh",
            JSON.stringify({ tool_input: { file_path: fp } }),
          );
          if (result.decision === "block") {
            throw new Error(
              result.reason ?? "Blocked: protected linter config",
            );
          }
        }
      }

      // Package-manager enforcement (Bash)
      if (tool === "bash") {
        const cmd = output.args?.command;
        if (typeof cmd === "string") {
          const result = runPreHook(
            "enforce_package_managers.sh",
            JSON.stringify({ tool_input: { command: cmd } }),
          );
          if (result.decision === "block") {
            throw new Error(
              result.reason ?? "Blocked: use the enforced package manager",
            );
          }
        }
      }
    },

    // ---- PostToolUse -------------------------------------------------------
    "tool.execute.after": async (input, output) => {
      if (!fileTools.has(input.tool)) return;

      const fp = extractFilePath(input.args);
      if (!fp) return;

      const hookInput = JSON.stringify({
        tool_name: toolNameMap[input.tool] ?? input.tool,
        tool_input: { file_path: fp },
      });

      let lintMessage: string | undefined;

      try {
        const stdout = execSync(
          `bash "${path.join(hooksDir, "multi_linter.sh")}"`,
          {
            input: hookInput,
            env: baseEnv,
            timeout: 600_000,
            encoding: "utf-8",
            stdio: ["pipe", "pipe", "pipe"],
          },
        );
        const result = JSON.parse(stdout.trim());
        if (result.systemMessage) lintMessage = result.systemMessage;
      } catch (err: unknown) {
        // exit code 2 = violations found (non-fatal)
        const execErr = err as { status?: number; stdout?: string };
        if (execErr.status === 2 && execErr.stdout) {
          try {
            const result = JSON.parse(execErr.stdout.trim());
            if (result.systemMessage) lintMessage = result.systemMessage;
          } catch {
            // parse failure -- fail open
          }
        }
      }

      if (lintMessage) {
        // Append linter findings to the tool output so the model sees them
        output.output = output.output
          ? `${output.output}\n\n[Plankton] ${lintMessage}`
          : `[Plankton] ${lintMessage}`;
      }
    },
  };
};
