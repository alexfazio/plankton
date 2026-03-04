#!/bin/bash
# init-typescript.sh - Initialize TypeScript support for Claude Code hooks
#
# Creates biome.json, tsconfig.json, package.json, .semgrep.yml and
# enables TypeScript in config.json. Idempotent - safe to run multiple times.
#
# Usage: bash scripts/init-typescript.sh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
config_file="${project_dir}/.claude/hooks/config.json"

echo "Initializing TypeScript support..."
echo ""

# --- 1. Create biome.json (skip if exists) ---
if [[ -f "${project_dir}/biome.json" ]]; then
  echo "[skip] biome.json already exists"
else
  cat >"${project_dir}/biome.json" <<'BIOME_EOF'
{
  "$schema": "https://biomejs.dev/schemas/2.3.11/schema.json",
  "vcs": {
    "enabled": true,
    "clientKind": "git",
    "useIgnoreFile": true,
    "defaultBranch": "main"
  },
  "files": {
    "ignoreUnknown": true
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 80,
    "lineEnding": "lf"
  },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "a11y": "error",
      "complexity": "warn",
      "correctness": "error",
      "performance": "warn",
      "security": "error",
      "style": "warn",
      "suspicious": "error",
      "nursery": "warn"
    }
  },
  "javascript": {
    "formatter": {
      "quoteStyle": "double",
      "trailingCommas": "all",
      "semicolons": "always"
    }
  },
  "assist": {
    "enabled": true,
    "actions": {
      "source": {
        "organizeImports": "on"
      }
    }
  }
}
BIOME_EOF
  echo "[created] biome.json"
fi

# --- 2. Create tsconfig.json (skip if exists) ---
if [[ -f "${project_dir}/tsconfig.json" ]]; then
  echo "[skip] tsconfig.json already exists"
else
  cat >"${project_dir}/tsconfig.json" <<'TSCONFIG_EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "dist"
  },
  "include": ["src"],
  "exclude": ["node_modules", "dist"]
}
TSCONFIG_EOF
  echo "[created] tsconfig.json"
fi

# --- 3. Create/merge package.json ---
if [[ -f "${project_dir}/package.json" ]]; then
  # Merge @biomejs/biome into existing devDependencies via jaq
  if command -v jaq >/dev/null 2>&1; then
    existing=$(cat "${project_dir}/package.json")
    has_biome=$(echo "${existing}" | jaq -r '.devDependencies."@biomejs/biome" // empty' 2>/dev/null)
    if [[ -z "${has_biome}" ]]; then
      echo "${existing}" | jaq '.devDependencies = (.devDependencies // {}) + {"@biomejs/biome": "^2.3.0"}' \
        >"${project_dir}/package.json.tmp" && mv "${project_dir}/package.json.tmp" "${project_dir}/package.json"
      echo "[updated] package.json (added @biomejs/biome)"
    else
      echo "[skip] package.json already has @biomejs/biome"
    fi
  else
    echo "[warning] jaq not found, cannot merge package.json. Add manually:"
    echo '  "devDependencies": { "@biomejs/biome": "^2.3.0" }'
  fi
else
  cat >"${project_dir}/package.json" <<'PKG_EOF'
{
  "private": true,
  "devDependencies": {
    "@biomejs/biome": "^2.3.0"
  }
}
PKG_EOF
  echo "[created] package.json"
fi

# --- 4. Create .semgrep.yml (skip if exists) ---
if [[ -f "${project_dir}/.semgrep.yml" ]]; then
  echo "[skip] .semgrep.yml already exists"
else
  cat >"${project_dir}/.semgrep.yml" <<'SEMGREP_EOF'
rules:
  # 1. Code Injection: eval() / new Function()
  - id: cc-hooks-no-eval
    patterns:
      - pattern-either:
          - pattern: eval($X)
          - pattern: new Function(...)
    message: >
      Avoid eval() and new Function() — they execute arbitrary code from
      strings, enabling code injection attacks.
    languages: [typescript, javascript]
    severity: ERROR
    metadata:
      cwe: "CWE-94: Improper Control of Generation of Code"

  # 2. XSS: innerHTML / dangerouslySetInnerHTML
  - id: cc-hooks-no-inner-html
    patterns:
      - pattern-either:
          - pattern: $EL.innerHTML = $X
          - pattern: dangerouslySetInnerHTML={{__html: $X}}
    message: >
      Setting innerHTML or dangerouslySetInnerHTML with dynamic content
      enables XSS attacks. Use textContent or a sanitization library.
    languages: [typescript, javascript]
    severity: ERROR
    metadata:
      cwe: "CWE-79: Cross-site Scripting (XSS)"

  # 3. Hardcoded Secrets: API keys and tokens
  - id: cc-hooks-no-hardcoded-secret
    patterns:
      - pattern: |
          $VAR = "..."
      - metavariable-regex:
          metavariable: $VAR
          regex: (?i).*(secret|password|api_key|apikey|token|auth).*
    message: >
      Possible hardcoded secret in variable assignment. Use environment
      variables or a secrets manager instead.
    languages: [typescript, javascript]
    severity: WARNING
    metadata:
      cwe: "CWE-798: Use of Hard-coded Credentials"

  # 4. SQL Injection: string concatenation in queries
  - id: cc-hooks-no-sql-concat
    patterns:
      - pattern-either:
          - pattern: $DB.query(`...${$X}...`)
          - pattern: $DB.query("..." + $X + "...")
          - pattern: $DB.execute(`...${$X}...`)
    message: >
      SQL query built with string concatenation is vulnerable to injection.
      Use parameterized queries or an ORM.
    languages: [typescript, javascript]
    severity: ERROR
    metadata:
      cwe: "CWE-89: SQL Injection"

  # 5. Command Injection: child_process with user input
  - id: cc-hooks-no-command-injection
    patterns:
      - pattern-either:
          - pattern: exec($CMD)
          - pattern: execSync($CMD)
          - pattern: child_process.exec($CMD)
          - pattern: child_process.execSync($CMD)
    message: >
      exec()/execSync() spawn a shell and are vulnerable to command
      injection. Use execFile() or spawn() with argument arrays instead.
    languages: [typescript, javascript]
    severity: WARNING
    metadata:
      cwe: "CWE-78: OS Command Injection"

  # 6. Path Traversal: unsanitized file paths
  - id: cc-hooks-no-path-traversal
    patterns:
      - pattern-either:
          - pattern: fs.readFile($PATH, ...)
          - pattern: fs.readFileSync($PATH, ...)
          - pattern: fs.writeFile($PATH, ...)
          - pattern: fs.writeFileSync($PATH, ...)
      - metavariable-pattern:
          metavariable: $PATH
          patterns:
            - pattern-not: "..."
    message: >
      File operation with dynamic path may allow path traversal. Validate
      and sanitize file paths before use.
    languages: [typescript, javascript]
    severity: WARNING
    metadata:
      cwe: "CWE-22: Path Traversal"

  # 7. JWT Misuse: hardcoded secrets
  - id: cc-hooks-no-jwt-hardcoded-secret
    patterns:
      - pattern-either:
          - pattern: jwt.sign($DATA, "...", ...)
          - pattern: jwt.verify($DATA, "...", ...)
    message: >
      JWT signed/verified with a hardcoded string secret. Use environment
      variables or a key management service.
    languages: [typescript, javascript]
    severity: ERROR
    metadata:
      cwe: "CWE-798: Use of Hard-coded Credentials"
SEMGREP_EOF
  echo "[created] .semgrep.yml"
fi

# --- 5. Update config.json to enable TypeScript ---
if command -v jaq >/dev/null 2>&1 && [[ -f "${config_file}" ]]; then
  jaq '.languages.typescript.enabled = true' "${config_file}" >"${config_file}.tmp" \
    && mv "${config_file}.tmp" "${config_file}"
  echo "[updated] config.json (typescript.enabled = true)"
else
  echo "[warning] Cannot update config.json. Set typescript.enabled to true manually."
fi

# --- 6. Print next steps ---
echo ""
echo "TypeScript support initialized."
echo ""
echo "Next steps:"
echo "  npm install          (or: pnpm install / bun install)"
echo ""
echo "Optional enhancements:"
echo "  npm i -D oxlint oxlint-tsgolint  (type-aware lint, 45 rules per-file)"
echo "  npm i -g @typescript/native-preview  (full type checking, session advisory)"
echo "  brew install semgrep   (security scanning)"
echo "  pip install semgrep    (alternative install method)"
echo "  npm i -D knip          (dead code detection, CI-recommended)"
