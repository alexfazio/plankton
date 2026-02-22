# Plankton

![Plankton mascot](assets/plankton-cover.png)

Real-time code quality enforcement for AI coding agents, built on Claude Code hooks.

AI coding agents write fast but they don't follow your rules. Formatting
drifts, naming conventions get ignored, dead code piles up as agents iterate
and refactor, and stylistic choices you actually care about (quote style,
import ordering, docstring format, complexity thresholds) get quietly
overridden on every edit. You end up in this endless loop of copy-pasting
pre-commit errors back into the agent, watching it fix half of them,
committing again, getting more errors. It's maddening. And the worst part:
agents will happily modify your linter configs to make violations disappear
instead of fixing the code. The rules get weaker and nobody notices.

Plankton enforces your standards programmatically at write-time, before
commits and code review. The agent is
blocked from proceeding until its output passes your checks. A three-phase
system auto-formats first (fixing ~40-50% of issues silently), collects
remaining violations as structured JSON via 20+ fast Rust-based linters, then
delegates what's left to dedicated Claude instances that reason about each
violation and produce targeted repairs. Model routing sends simple fixes to
fast models and complex refactoring to capable ones, right-sizing intelligence
to problem complexity so tokens aren't wasted. Covers Python, TypeScript/
JS/CSS, Shell, YAML, Markdown, Dockerfile, TOML, and JSON — 8 languages, each
with its own enforcement pipeline.

Agentic coding created a [new programmable
layer](https://x.com/karpathy/status/2004607146781278521): agents, hooks,
MCP, permissions, tools. Everyone's still figuring out how to hold it.
Plankton is the enforcement dimension of that layer.

Like the organism: tiny, everywhere, filtering everything.

> [!CAUTION]
> Research project under active development. Hooks are tested against
> Claude Code >= 2.1.50 (see badge). Newer CC versions usually work
> but are not guaranteed. **Disable CC auto-updates** to prevent
> silent breakage (see Quick Start). If you encounter issues, file a
> report including the output of `claude --version`.

## quick start

1. **Disable Claude Code auto-updates** (recommended). Plankton depends on
   undocumented CC internals — a silent auto-update can break hooks without
   warning. Pick one:

   ```bash
   # Option A: disable auto-updates entirely (most reliable)
   echo 'export DISABLE_AUTOUPDATER=1' >> ~/.zshrc && source ~/.zshrc

   # Option B: use the stable channel (~1 week behind latest, fewer regressions)
   curl -fsSL https://claude.ai/install.sh | bash -s stable
   ```

   Check your current version: `claude --version`

   Tested with Claude Code >= 2.1.50.

2. **Clone the repository**:

   ```bash
   git clone https://github.com/alexfazio/plankton.git
   cd plankton
   ```

3. **Install dependencies**:

   ```bash
   pip install uv
   uv sync --all-extras
   ```

4. **Start a Claude Code session**. Hooks activate automatically.

Only `jaq` and `ruff` are required. Everything else is optional and
gracefully skipped if not installed. See [docs/SETUP.md](docs/SETUP.md)
for per-language installation and configuration.

## verify

```bash
# Install pre-commit hooks (optional but recommended)
uv run pre-commit install

# Run the hook self-test suite
.claude/hooks/test_hook.sh --self-test
```

## how it works

I built Plankton because I was tired of the copy-paste loop. You tell the
agent your rules, it ignores half of them, you commit, pre-commit hooks catch
15 violations, you paste them back in, the agent fixes 12, you commit again, 3
more appear. Round and round. Worse, I noticed agents exhibit rule-gaming
behavior: instead of fixing code, they quietly modify your `.ruff.toml` or
`biome.json` to make violations disappear. The rules get weaker and nobody
notices. I wanted something that enforced quality as a structural constraint,
not a suggestion.

The system runs in three phases. Phase 1 auto-formats silently: ruff, shfmt,
biome, taplo, markdownlint — fixing formatting issues before anyone sees them.
Phase 2 collects remaining violations as structured JSON with line numbers,
column positions, and violation codes from every configured linter. Phase 3
delegates those violations to a dedicated Claude subprocess that reasons about
each fix, applies targeted edits, then the hook re-runs Phase 1 and 2 to
verify the result. If violations remain, they're escalated to the main agent
with full context.

Config protection is non-negotiable. A PreToolUse hook blocks edits
to all 14+ linter config files before they happen, and a Stop hook
uses git diff to catch anything that slipped through at session end.

Model routing picks the right size of intelligence for each problem: haiku for
simple unused-variable deletions (~5s), sonnet for complexity refactoring and
docstring rewrites (~15s), opus when there are 5+ violations or architectural
type errors (~25s). Tokens aren't wasted on easy fixes; hard problems get the
reasoning they need.

The Boy Scout Rule ties it together: edit a file, own all its
violations, pre-existing or not. No exceptions. Like reinforcement
learning signals, these
corrections shape how the agent writes code, actively preventing bad patterns
rather than cleaning up after the fact.

See [docs/REFERENCE.md](docs/REFERENCE.md) for the full architecture, message
flows, and configuration reference.

## what it enforces

Style enforcement covers formatting, import ordering, naming
conventions, docstring format, quote style, indentation, trailing
commas, modern syntax idioms (Python 3.11+ f-strings, modern type
annotations). Most of this is handled silently by auto-formatting in
Phase 1. You never see these violations because they're fixed before
they're reported.

Correctness checks catch unused variables, type errors (ty), dead
code (vulture, Knip), security vulnerabilities (bandit, Semgrep),
async anti-patterns (flake8-async), Pydantic model validation,
duplicate code detection (jscpd), ShellCheck semantic analysis with
all optional checks enabled, Dockerfile best practices (hadolint at
maximum strictness), YAML strictness with all 23 yamllint rules
configured. Phase 2 linters catch these; Phase 3 Claude instances
fix them.

Architectural constraints are emerging: complexity limits (cyclomatic
complexity, max arguments, max nesting depth, max statements per
function), package manager compliance (blocks pip/npm/yarn, enforces
uv/bun), config file protection with tamper-proof defense. These
shape how code is organized rather than how it looks.

## configuration

`.claude/hooks/config.json` controls everything: language toggles, phase
control, model routing patterns, protected files, exclusions, jscpd
thresholds, package manager enforcement modes. If the file is missing, all
features are enabled with sensible defaults. Environment variables
(`HOOK_SKIP_SUBPROCESS=1`, `HOOK_SUBPROCESS_TIMEOUT`) override config values
for quick session-level tweaks. Every rule is customizable. Configure what
gets enforced, how strictly, and for which languages. Full configuration
reference in [docs/REFERENCE.md](docs/REFERENCE.md).

## faq

See [docs/FAQ.md](docs/FAQ.md) for answers to common questions: how this
differs from pre-commit hooks, whether models will make this unnecessary, why
agents modify linting rules, and more.

## todos

- should have an install wizard instead of manual setup, a guided script that
  detects your stack and configures everything
- one-click install via Claude Code marketplace would be nice
- a Claude Code skill for configuration and troubleshooting from inside a
  session
- Swift and Go are next
- model routing currently assumes Anthropic models, need to support any model
  Claude Code supports (Qwen, DeepSeek, Gemini, etc.) with a generic
  three-tier system users map to their provider
- per-directory rule overrides, team config profiles
- extend beyond code to catch AI writing slop in docs and READMEs
  ([slop-guard](https://github.com/eric-tramel/slop-guard) integration)
- `multi_linter.sh` is ~1,300 lines and should split into one file per hook type
- 103-test integration suite exists but needs work; Claude subprocess
  stochasticity makes deterministic assertions hard
- measuring LLM+Plankton vs LLM-alone would be useful but needs benchmarking
  expertise, contributions welcome here

Contributions are welcome.

## Star History

<!-- markdownlint-disable MD033 MD013 -->
<a href="https://star-history.com/#alexfazio/plankton&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=alexfazio/plankton&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=alexfazio/plankton&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=alexfazio/plankton&type=Date" />
 </picture>
</a>
<!-- markdownlint-enable MD013 -->
<!-- markdownlint-enable MD033 -->

## license

MIT
