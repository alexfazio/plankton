import type { Plugin } from "@opencode-ai/plugin";
import { execSync } from "child_process";
import * as path from "path";

export const PlanktonPlugin: Plugin = async ({ directory }) => {
  const hooksDir = path.join(directory, ".claude", "hooks");

  const baseEnv = {
    ...process.env,
    PLANKTON_PROJECT_DIR: directory,
    PLANKTON_DELEGATE_CMD: "opencode",
    PLANKTON_PROTECTED_DIRS: ".claude:.plankton:.opencode",
  };

  const toolNameMap: Record<string, string> = {
    write: "Write",
    edit: "Edit",
    bash: "Bash",
  };

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
    "tool.execute.before": async (input, _output) => {
      const tool = input.tool;

      // Config protection (Edit/Write)
      if (["write", "edit"].includes(tool)) {
        const fp = input.args?.file_path || input.args?.path;
        if (fp) {
          const result = runPreHook(
            "protect_linter_configs.sh",
            JSON.stringify({ tool_input: { file_path: fp } }),
          );
          if (result.decision === "block") {
            return { blocked: true, reason: result.reason };
          }
        }
      }

      // Package manager enforcement (Bash)
      if (tool === "bash") {
        const cmd = input.args?.command;
        if (cmd) {
          const result = runPreHook(
            "enforce_package_managers.sh",
            JSON.stringify({ tool_input: { command: cmd } }),
          );
          if (result.decision === "block") {
            return { blocked: true, reason: result.reason };
          }
        }
      }

      return input;
    },

    "tool.execute.after": async (input, output) => {
      if (!["write", "edit"].includes(input.tool)) return output;
      const fp = input.args?.file_path || input.args?.path;
      if (!fp) return output;

      const hookInput = JSON.stringify({
        tool_name: toolNameMap[input.tool] || input.tool,
        tool_input: { file_path: fp },
      });

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
        if (result.systemMessage) output.systemMessage = result.systemMessage;
      } catch (err: unknown) {
        const execErr = err as { status?: number; stdout?: string };
        if (execErr.status === 2 && execErr.stdout) {
          try {
            const result = JSON.parse(execErr.stdout.trim());
            if (result.systemMessage)
              output.systemMessage = result.systemMessage;
          } catch {
            // parse failure, ignore
          }
        }
      }
      return output;
    },
  };
};
