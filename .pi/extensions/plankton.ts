import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { execSync, exec } from "child_process";
import * as path from "path";
import { promisify } from "util";

const execAsync = promisify(exec);

export default function (pi: ExtensionAPI) {
  const projectDir = process.cwd();
  const hooksDir = path.join(projectDir, ".claude", "hooks");

  const baseEnv = {
    ...process.env,
    PLANKTON_PROJECT_DIR: projectDir,
    PLANKTON_DELEGATE_CMD: "pi",
    PLANKTON_PROTECTED_DIRS: ".claude:.plankton:.pi",
  };

  const toolNameMap: Record<string, string> = {
    write: "Write",
    edit: "Edit",
    read: "Read",
    bash: "Bash",
  };

  // PreToolUse: block protected configs and enforce package managers
  pi.on("tool_call", async (event, _ctx) => {
    const tool = event.toolName;
    const filePath = event.input?.file_path || event.input?.path;

    // PreToolUse: protect configs (Edit/Write)
    if (["write", "edit"].includes(tool) && filePath) {
      const preInput = JSON.stringify({ tool_input: { file_path: filePath } });
      try {
        const preOut = execSync(
          `bash "${path.join(hooksDir, "protect_linter_configs.sh")}"`,
          {
            input: preInput,
            env: baseEnv,
            timeout: 5_000,
            encoding: "utf-8",
            stdio: ["pipe", "pipe", "pipe"],
          },
        );
        const preResult = JSON.parse(preOut.trim());
        if (preResult.decision === "block") {
          return {
            block: true,
            reason: preResult.reason || "Protected file",
          };
        }
      } catch {
        // fail-open: if hook errors, allow the operation
      }
    }

    // PreToolUse: enforce package managers (Bash)
    if (tool === "bash") {
      const cmd = event.input?.command;
      if (cmd) {
        const preInput = JSON.stringify({ tool_input: { command: cmd } });
        try {
          const preOut = execSync(
            `bash "${path.join(hooksDir, "enforce_package_managers.sh")}"`,
            {
              input: preInput,
              env: baseEnv,
              timeout: 5_000,
              encoding: "utf-8",
              stdio: ["pipe", "pipe", "pipe"],
            },
          );
          const preResult = JSON.parse(preOut.trim());
          if (preResult.decision === "block") {
            return {
              block: true,
              reason: preResult.reason || "Blocked package manager",
            };
          }
        } catch {
          // fail-open
        }
      }
    }
  });

  // PostToolUse: lint after file edits
  pi.on("tool_result", async (event, _ctx) => {
    const tool = event.toolName;
    if (!["write", "edit"].includes(tool)) return;

    const filePath = event.input?.file_path || event.input?.path;
    if (!filePath) return;

    const input = JSON.stringify({
      tool_name: toolNameMap[tool] || tool,
      tool_input: { file_path: filePath },
    });

    let lintMessage: string | undefined;

    try {
      const { stdout } = await execAsync(
        `echo ${JSON.stringify(input)} | bash "${path.join(hooksDir, "multi_linter.sh")}"`,
        {
          env: baseEnv,
          timeout: 600_000,
          encoding: "utf-8",
        },
      );
      const result = JSON.parse(stdout.trim());
      if (result.systemMessage) {
        lintMessage = result.systemMessage;
      }
    } catch (err: unknown) {
      const execErr = err as { code?: number; stdout?: string };
      if (execErr.code === 2 && execErr.stdout) {
        try {
          const result = JSON.parse(execErr.stdout.trim());
          if (result.systemMessage) lintMessage = result.systemMessage;
        } catch {
          // parse failure, ignore
        }
      }
    }

    if (lintMessage) {
      // Append lint results to the tool result content
      const existingText =
        event.content
          ?.filter(
            (c: { type: string }) => c.type === "text",
          )
          .map((c: { text: string }) => c.text)
          .join("\n") || "";

      return {
        content: [
          {
            type: "text" as const,
            text: existingText
              ? `${existingText}\n\n[Lint] ${lintMessage}`
              : `[Lint] ${lintMessage}`,
          },
        ],
      };
    }
  });
}
