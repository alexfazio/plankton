# Plankton Linting Agent

This project uses Plankton for multi-language linting. The Pi extension at
`.pi/extensions/plankton.ts` runs linting hooks after file edits and blocks
modifications to protected config files.

## Linting behavior

- After each Write/Edit, the linter runs and reports violations as system messages
- Fix the code based on violation messages; do not modify linter config files
- Protected files (`.ruff.toml`, `biome.json`, etc.) are immutable
- Use `uv` instead of pip/poetry for Python packages
- Use `bun` instead of npm/yarn/pnpm for JavaScript packages

## Config

Linting config lives in `.plankton/config.json` (fallback: `.claude/hooks/config.json`).
