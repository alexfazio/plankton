# ADR: Plankton Code Quality Benchmark

**Status**: Draft
**Date**: 2026-02-22
**Author**: alex fazio + Claude Code research synthesis

## Context and Problem Statement

Plankton is a multi-linter hook system for Claude Code that enforces code
quality at WRITE-TIME (the first of its kind) via a three-phase pipeline
(auto-format, collect violations, delegate+verify). Enforcing quality
control at write-time doesn't just catch violations — it fundamentally
changes the model's behavior. The feedback loop teaches the model to
produce cleaner code patterns, avoid common anti-patterns, and self-correct
during generation rather than after.

While the system works in practice, there is no quantitative evidence of
its impact. We need to run an existing, recognized coding benchmark on
Claude Code — once with Plankton active, once without — and compare
the results. The benchmark itself measures task correctness (pass/fail);
Plankton's impact shows up as a change in pass rate, indicating that
write-time quality enforcement improves overall code output.

Claude Code is an agent loop — it gathers context via tools, takes
actions, verifies results, and iterates. Both conditions (baseline
and Plankton) get the same full agent capabilities. The only variable
is whether Plankton hooks are active. This tests the full product,
not an isolated signal.

To get a believable, publishable result the benchmark must freeze:

- **Task set and tests** — benchmark version pinned to a specific commit
- **Model identity** — use fixed model IDs, never "latest" aliases
- **Tool/permission budget** — especially whether the agent can run
  tests during generation
- **Hook configuration** — because hooks are the independent variable

Key hypotheses to test:

1. **Higher pass rate** — write-time feedback catches bugs, type errors,
   and anti-patterns that would otherwise cause test failures.
2. **Behavioral shift** — with Plankton active, the model learns from
   write-time feedback and produces better code *during* generation,
   not just through post-hoc formatting.
3. **Compound quality** — improvements across multiple dimensions
   (style, types, security, complexity) compound into code that is
   more likely to be functionally correct.

### Requirements

1. **Runs on Claude Code** — any benchmark that can run on Claude Code
   works, since Plankton is just a Claude Code hooks extension running
   in the background. No special harness integration needed.
2. **Existing benchmark** — use a recognized, published benchmark. We
   are not building a custom benchmark harness.
3. **Tool-use native** — tasks must naturally involve file editing
   (the agent uses Edit/Write tools), not text completion. This is
   required because Plankton hooks fire on Edit/Write tool use — a
   text-completion benchmark would bypass hooks entirely.
4. **Cheap first run** — initial results for ~$100-300 in API costs.
5. **Reproducible** — fixed prompts, deterministic test suites.

## Benchmark Landscape Research

An exhaustive survey of existing benchmarks and major leaderboards
(Scale SEAL, Vellum, Artificial Analysis, Arena.ai, Aider) was
conducted. All existing coding benchmarks measure functional
correctness (tests pass / tests fail). None natively measure code
quality via linter metrics. This is fine for our purposes — we use
their pass rate as the primary metric and let Plankton's impact
show up as a correctness improvement.

### Text-completion vs tool-use benchmarks

A critical insight discovered during Phase 2: coding benchmarks fall
into two paradigms, and the choice fundamentally affects whether
Plankton can be tested:

| Paradigm | How code is produced | Hooks fire? | Examples |
| --- | --- | --- | --- |
| **Text-completion** | Outputs code as text | **No** | HumanEval, MBPP |
| **Tool-use agent** | Edits files via tools | **Yes** | SWE-bench, IDE-Bench |

Plankton hooks fire on PostToolUse events for Edit and Write tools.
If the model outputs code as text (text-completion paradigm), no
tools are invoked, hooks never fire, and the Plankton condition is
identical to baseline. Text-completion benchmarks can be adapted
(by prompting the model to "Edit solution.py" instead of "complete
this function"), but this changes the task — the results are no
longer measuring what the benchmark measures, reducing scientific
validity (see Alternatives Considered for details).

**Tool-use agent benchmarks** are the correct paradigm for Plankton.
The agent naturally edits files as part of its workflow, hooks fire
organically, and no prompt adaptation is needed.

### Recommended benchmarks

| Benchmark | Tasks | Languages | Paradigm | Fit | Notes |
| --- | --- | --- | --- | --- | --- |
| **[SWE-bench Verified Mini][swebench-mini]** | 50 | Python | Tool-use | **Best** | Public leaderboard, cheap, hooks fire naturally |
| **[SWE-bench Verified][swebench]** | 500 | Python | Tool-use | **Scale-up** | Full benchmark after methodology validated |
| **[FeatureBench][featurebench]** | 200 | Python | Tool-use | **Future** | Feature implementation, not just bug-fixing |

[swebench]: https://www.swebench.com
[swebench-mini]: https://hal.cs.princeton.edu/swebench_verified_mini
[featurebench]: https://arxiv.org/abs/2602.10975

### Benchmark deep dives

#### SWE-bench Verified Mini: the right paradigm for Plankton

SWE-bench Verified Mini is a curated 50-task subset of SWE-bench
Verified (500 tasks, human-annotated by software engineers). Tasks
are bug-fixing in real Python repos (Django, Flask, scikit-learn,
sympy). The agent receives a GitHub issue description and the full
codebase at the relevant commit, then edits files to produce a patch.
Both conditions have full access to the repo's test files and can
self-correct via pytest. The gold patch is withheld, but test files
are present in the checkout and `FAIL_TO_PASS` test identifiers are
provided in the task metadata.

Evaluation: the harness applies the agent's patch in a Docker
container and runs the repo's test suite. Two checks: FAIL_TO_PASS
(the fix works) and PASS_TO_PASS (nothing else broke). Both must
pass for the task to count as resolved.

Why it fits Plankton: the agent naturally uses Edit/Write tools to
modify source files. Plankton hooks fire on every edit, providing
lint feedback that can prevent wasted turns. Research shows **51.7%
of SWE-agent trajectories had 1+ failed edits due to linting
errors** — exactly what Plankton addresses.

The [HAL harness][hal] (Princeton) supports arbitrary agents
including Claude Code. It provides `swebench_verified_mini` as a
built-in benchmark with cost tracking via Weave.

[hal]: https://github.com/princeton-pli/hal-harness

#### SWE-bench Verified: full-scale follow-up

500 human-verified tasks from SWE-bench. Human-annotated difficulty
breakdown: 196 "easy" tasks (<15 min fix), 45 "hard" tasks (>1 hour).
Use after methodology is validated on the Mini subset.

#### FeatureBench: feature implementation (future)

200 tasks from 24 Python repos. Unlike SWE-bench (bug-fixing),
FeatureBench evaluates feature implementation — agents edit existing
code or build from scratch. Evaluation via pytest (fail-to-pass and
pass-to-pass). A strong candidate for Phase 3 if we want to test
Plankton on feature work rather than bug-fixing.

#### Aider Polyglot: strong dataset, harness not plug-and-play

Widely referenced, 225 Exercism exercises across six languages, designed
around autonomous "edit files, run tests, maybe try again" behaviour.
Exercises live in a dedicated repository sourced from Exercism tracks.

The official Aider benchmark harness evaluates "Aider + model" behaviour
because Aider is the agent that applies edits, decides on retries, and
formats patches. The harness will not exercise Claude Code hooks unless
task execution is re-routed through Claude Code. Conclusion: great
dataset, not a plug-and-play harness for the Plankton hypothesis.

#### BigCodeBench: excellent realism, heavier operationally

The BigCode Project built BigCodeBench as "HumanEval-like function-level
tasks" with much more complex instructions and many library/tool calls.
It offers splits for "Complete" vs "Instruct" and a "Hard" subset
aligned with real-world tasks.

The official CLI (`bigcodebench.evaluate`) generates, executes in
sandboxes (remote or local), and writes structured outputs including
pass@k files. The authors warn that batch inference (e.g. with vLLM)
can introduce variability, and recommend batch size 1 for more
deterministic greedy decoding.

BigCodeBench is a strong second benchmark once A/B methodology is
solid — it stress-tests "real-ish programming" rather than
Exercism-style puzzles, but is operationally more complex (sandbox
backends, dataset versions, execution options).

#### ClassEval: good "medium complexity" Python benchmark

FudanSELab's ClassEval provides 100 class-level Python tasks with
hundreds of methods and explicit dependency types (library, field, and
method dependencies). The project documents generation strategies
(holistic vs incremental vs compositional) and provides a structured
JSON dataset with skeletons and tests. If Exercism feels toy-ish,
ClassEval is the cleanest "cheap but non-trivial" option.

#### EvalPlus / HumanEval+: fast and famous, very small code

EvalPlus wraps HumanEval with dramatically expanded tests
(HumanEval+), and documents both a Docker-based safe evaluator and
practical speed/timeout knobs (parallelism, `--mini`, etc.). Good as a
calibration run and for quick iteration, but because tasks are small
(single functions of ~10-20 lines), it may under-measure the kind of
multi-dimensional "quality compounding" the ADR is betting on.

#### MultiPL-E: the most defensible path for TypeScript

If TypeScript is truly needed in the MVP, the cleanest "existing
benchmark" route is MultiPL-E's TypeScript translations of
HumanEval/MBPP (unit tests translated across languages). The MultiPL-E
paper explicitly includes TypeScript among evaluated languages, and the
dataset is published on Hugging Face. It will not give big multi-file
projects, but it provides an honest, recognized, execution-based
TypeScript benchmark without inventing custom tasks.

### Harness comparability

SWE-bench Verified separates evaluation from the agent. The harness
provides (tasks + tests + Docker evaluator) with no opinion on which
agent generates the patch. Results are directly comparable to
published leaderboard numbers (HAL, Anthropic, OpenAI all report
on the same task set with the same evaluator).

The HAL harness is the recommended evaluation framework. It supports
arbitrary agents, tracks costs, and hosts the official Verified Mini
leaderboard. Alternative options:

| Harness | Strengths | Considerations |
| --- | --- | --- |
| **HAL harness** | Official leaderboard, costs | Less battle-tested |
| **SWE-agent** | Battle-tested, Claude support | Own tool interface |
| **sb-cli** | Official CLI, lightweight | Eval-only (patches) |

### Not recommended

| Benchmark | Why it doesn't fit |
| --- | --- |
| **EvalPlus / HumanEval+** | Text-completion; tasks too simple. |
| **ClassEval** | Text-completion; pilot +5.3%, weak validity. |
| **Terminal-Bench** | Terminal/CLI tasks, not code generation. No code files. |
| **CodeContests** | ~13.6k competitive-programming tasks — too algorithmic. |
| **CRUXEval** | Input/output prediction only, not code generation. |
| **Arena.ai code LB** | Human-vote Elo, no deterministic metrics. |

### Leaderboards surveyed

| Leaderboard | Code benchmarks tracked | Notes |
| --- | --- | --- |
| [Scale SEAL](https://scale.com/leaderboard) | SWE-Bench Pro | No simple/medium code-gen benchmarks |
| [Vellum](https://www.vellum.ai/llm-leaderboard) | SWE-Bench, Aider Polyglot, BFCL | Aider Polyglot is the best fit |
| [Artificial Analysis](https://artificialanalysis.ai/methodology/intelligence-benchmarking) | SciCode, Terminal-Bench Hard | SciCode is Python but scientific computing |
| [Arena.ai](https://arena.ai/leaderboard/code) | Code arena (Elo votes) | Human preference, not deterministic |
| [Aider](https://aider.chat/docs/leaderboards/) | Aider Polyglot | Primary recommendation |

## Decision

### D1: Two-condition A/B design

Every task is run twice with the same model:

| Condition | Description |
| --- | --- |
| **A (baseline)** | `cc -bare`: no hooks, settings, or MCPs (see below) |
| **B (plankton)** | Claude Code with Plankton hooks active (default settings) |

`cc -bare` is a custom zsh wrapper that expands to:

```bash
claude --setting-sources '' \
       --settings ~/.claude/bare-settings.json \
       --strict-mcp-config \
       --disable-slash-commands
```

Where `bare-settings.json` contains only `{"disableAllHooks": true}`.
The flags achieve isolation as follows: `--setting-sources ''` empties
the settings cascade (no user/project/local layers), `--strict-mcp-config`
without a `--mcp-config` argument disables all MCP servers, and
`--disable-slash-commands` prevents skills from loading. The combined
effect is a Claude Code session with no hooks, no MCPs, no skills, and
no inherited settings.

> **Verification required**: The exact interaction of `--setting-sources ''`
> with `--settings` is not fully documented. Before benchmark runs,
> empirically verify that condition A produces zero hook activity by
> running a test task and checking for PostToolUse hook invocations.
>
> - **Finding** [MEDIUM]: GH issues (#11652, #11872, #11392, SDK #186) show
> empty `--setting-sources` can cause errors or unintended setting merging.
> The `--settings` flag appears additive/independent of `--setting-sources`
> scopes, but this is undocumented. **Recommendation**: Empirical verification
> essential. If `--setting-sources ''` errors, omit it and rely on
> `bare-settings.json` with `disableAllHooks: true`.

**CLAUDE.md handling**: Before any benchmark tasks begin, rename
`CLAUDE.md` to `CLAUDE.md.bak` in the benchmark working directory.
This must happen once, up front, before all tests start — not
per-task. Neither condition should be steered by project instructions.
Hooks are the only variable.

This isolates Plankton as the only variable. The benchmark's own test
suite determines pass/fail — we compare pass rates between conditions.

**Task ordering**: Run conditions interleaved per task, but
**randomize the A/B order per task** using a coin flip (seeded PRNG
for reproducibility). For each task N, flip to decide whether A or B
runs first, then run the other condition. This eliminates systematic
second-position advantage (API caching, endpoint warmth) while still
minimizing the time gap between paired conditions. Record the random
seed in results metadata.

### D2: Use SWE-bench Verified Mini as primary benchmark

Plankton is a tool-use intervention — hooks fire when the agent
invokes Edit/Write tools. The benchmark must use the **tool-use
agent paradigm** where the agent naturally edits files as part of
its workflow. Text-completion benchmarks (HumanEval, ClassEval)
require prompt adaptation that reduces scientific validity (see
Alternatives Considered).

**Primary: SWE-bench Verified Mini (50 tasks)** — a curated subset
of SWE-bench Verified with a public HAL leaderboard. Tasks are
bug-fixing in real Python repos. The agent naturally uses Edit tools,
hooks fire organically, and no prompt adaptation is needed. Research
shows 51.7% of agent trajectories hit lint errors — exactly
Plankton's domain. Results are directly comparable to published
leaderboard numbers via the HAL harness.

**Scale-up: SWE-bench Verified (500 tasks)** — the full benchmark
after methodology is validated on Mini. Provides statistical power
and broader task coverage.

**Future: FeatureBench (200 tasks)** — feature implementation (not
just bug-fixing) across 24 Python repos. Tests whether Plankton
helps with building new code, not just fixing existing code.

### D3: Focus on Python

The MVP focuses on **Python** — SWE-bench Verified is Python-only
(Django, Flask, scikit-learn, sympy, etc.) and Python is where
Plankton's tooling coverage is deepest (ruff, ty, ruff format).
TypeScript coverage can be tested later via FeatureBench or a
custom Exercism-based evaluation if needed.

### D4: Metrics

The primary metric is the benchmark's own **pass rate** — the
percentage of tasks where the generated code passes the test suite.

| Metric | Source | What it captures |
| --- | --- | --- |
| **Pass rate** | Benchmark test suite | Does Plankton improve correctness? |
| **Pass rate delta** | Plankton − baseline | Net impact of enforcement |

Optional secondary metrics (for deeper analysis):

| Metric | How | What it captures |
| --- | --- | --- |
| Violation count | Run linters post-hoc on output | Quality beyond tests |
| Violation density | Violations / LOC | Quality normalized by size |
| Clean file rate | Zero-violation files / total | Consistency |

### D5: What we're NOT measuring (scope exclusions)

| Out of scope | Reason |
| --- | --- |
| Code readability (subjective) | Requires LLM judge, not deterministic |
| Performance/runtime | Orthogonal to code quality |
| Test coverage of generated code | Requires instrumented execution |
| Developer satisfaction | Requires user study |
| Hook latency/overhead | Operational concern; 3x overhead is extra compute |
| Full linter chain coverage | Benchmark focuses on Python only (D3) |

## Alternatives Considered

### Experimental design

**Crossover design** (each task run Plankton-first then baseline, and
vice versa for another set) was considered but rejected. Coding tasks
are independent — there is no order effect or learning carryover
between tasks. A simple paired A/B design is sufficient and halves
the number of runs compared to a full crossover.

**Chi-squared test instead of McNemar's** was rejected because the
data is paired, not independent. The same 50 tasks are run in both
conditions, producing paired binary outcomes (pass/fail under baseline,
pass/fail under Plankton). McNemar's test (or the mid-p variant)
correctly accounts for this pairing by focusing on discordant pairs
(tasks that flip between conditions). A chi-squared test on unpaired
proportions would ignore the task-level pairing and lose statistical
power.

**Multiple repetitions per task** are deferred. If Phase 2 (single
run, 50 tasks) produces a clear signal (8+ discordant pairs),
repetitions add cost without information. If the signal is borderline
(3-7 flips), Phase 3 adds 3 repetitions per task to firm up the
result.

### Benchmark selection (rejected: text-completion benchmarks)

**EvalPlus / HumanEval+** and **ClassEval** were the original primary
benchmarks (see Implementation Log for Phase 1-2 history). Both were
rejected after Phase 2 revealed a fundamental paradigm mismatch:

1. **Text-completion paradigm**: These benchmarks are designed for
   models that output code as text. The model receives a prompt and
   produces a code string. No file editing tools are involved.
2. **Plankton requires tool use**: Plankton hooks fire on Edit/Write
   tool invocations. If no tools are used, hooks never fire.
3. **Prompt adaptation is scientifically weak**: To make hooks fire,
   the prompt was adapted from "complete this function" to "Edit
   solution.py to implement...". This changes the task — the results
   no longer measure what the benchmark measures. While the A/B
   comparison between conditions remains valid (both use the same
   adapted prompt), the results are not comparable to published
   benchmark numbers, and the adaptation introduces an artificial
   element to the experiment.
4. **Empirical evidence**: HumanEval+ tasks (10-20 line single
   functions) proved too simple — 8 completed tasks showed identical
   algorithms across conditions. ClassEval pilot (20 tasks) showed
   +5.3% with the adapted prompt, but with only 1 discordant pair
   and the scientific validity concern, this was insufficient to
   justify continued investment.

SWE-bench Verified Mini was selected instead because it uses the
**tool-use agent paradigm** — the agent naturally edits files,
hooks fire organically, and no prompt adaptation is needed.

## Benchmark Operational Details

How each benchmark's authors expect you to run things.

### Aider benchmark harness

Designed to run inside Docker because it executes LLM-generated code
(the authors call out that this could be dangerous, giving the example
of a destructive Python command).

Workflow: clone the Aider repo, clone Polyglot benchmark exercises into
a scratch directory, build the benchmark Docker image, run the container
and execute `./benchmark/benchmark.py …` with model name, edit format,
and thread count.

Key operational flags:

- `--threads` — parallelism
- `--num-tests` and `--keywords` — partial runs
- `--read-model-settings` / model settings files — per-model behaviour

Produces a YAML stats report containing `pass_rate_1`, `pass_rate_2`,
and additional run metadata (commit hash, elapsed time per case, total
cost, malformed response counts, etc.).

### BigCodeBench

CLI-centric workflow: install from pip, run `bigcodebench.evaluate`
specifying execution mode (`e2b`, `gradio`, `local`), split (`instruct`
vs `complete`), subset (`full` vs `hard`), and backend (`anthropic`,
`openai`, `vllm`, etc.).

Writes outputs under a results directory using file naming conventions
that encode model, split, backend, temperature, and sample count.
Writes separate JSON files for pass@k.

The authors warn that batch inference can change results across batch
sizes/versions in vLLM, and recommend batch size 1 for more
deterministic greedy decoding. Official evaluation notes acknowledge
dataset errata/bugs can exist — pin dataset versions and record them.

### ClassEval

Requires Python 3.8 or newer, installing the repo as a package, keeping
`ClassEval_data.json` in the `data/` directory, and placing model
outputs in a consistent JSON structure under `output/model_output`.

The original work evaluated both greedy and nucleus sampling, and
compares multiple generation strategies — this matters because
reviewers will ask which generation strategy and sampling regime was
followed.

### EvalPlus

Recommends Docker sandboxes for safety. Defines timeouts in terms of a
base timeout and a ground-truth-runtime multiplier; suggests increasing
these if high variance is observed on slow machines.

Speed tips: avoid `--test-details` if only pass@k is needed, use
`--mini` for HumanEval+ Mini.

## Implementation Plan

### Harness: Claude Code headless mode

Claude Code's programmatic mode is `claude -p …` (print mode, formerly
headless mode). It supports:

- Structured output (`--output-format json`) — **used**
- Task isolation via worktrees (`--worktree`) — available for manual
  execution; redundant under HAL harness which provides per-task
  filesystem isolation natively (`/tmp/agent_run_<uuid>/`)
- Loading settings from file/JSON string (`--settings`) plus
  controlling which settings scopes load (`--setting-sources`) — **used**
- Permission bypass (`--dangerously-skip-permissions`) — **used**
- Auto-approvals (`--allowedTools`) — available as a more granular
  alternative to `--dangerously-skip-permissions`

This is enough to build a repeatable, safe, truly A/B benchmark runner.

### Making hooks the only variable

Hooks can be disabled globally by setting `"disableAllHooks": true` in
settings. There is no per-hook toggle in the same configuration layer.
Hooks config is scoped via settings files: user
(`~/.claude/settings.json`), project (`.claude/settings.json`), local
(`.claude/settings.local.json`).

Two important operational constraints:

1. Claude Code snapshots hooks at startup and uses them for the entire
   session. You cannot reliably flip hooks mid-session without a
   restart.
2. In managed enterprise environments, hooks may be enforced via
   managed settings, and lower-scope `disableAllHooks` will not
   override managed hooks unless applied at managed level. If
   benchmarking on a corporate machine with managed settings, the
   "baseline no hooks" condition may be impossible unless IT cooperates
   or the environment is isolated.

### Concrete A/B protocol (per task)

**Task source**: SWE-bench Verified Mini (50 tasks) via the HAL
harness. Each task provides a GitHub issue description and the full
codebase at the relevant commit. The agent edits files to produce a
patch. No prompt adaptation needed — the agent naturally uses Edit
tools, and hooks fire organically.

**Harness**: Princeton HAL harness (`princeton-pli/hal-harness`).
Supports arbitrary agents via a custom agent function. Write a thin
wrapper that invokes `claude -p` (Plankton condition) or `cc -bare -p`
(baseline) and returns the resulting patch.

- **Finding** [HIGH]: HAL harness confirmed as best fit — supports custom agents
  via `run(input, **kwargs) -> dict`, Docker eval, Weave cost tracking. sb-cli
  is eval-only (no agent execution). HAL actively maintained (Feb 2026).
  Limitations: Weave may conflict with Claude Code subprocess spawning
  ([HAL harness](https://github.com/princeton-pli/hal-harness)).
  ARM64/Mac M-series limitation resolved locally (2026-02-23).
  **Recommendation**: Proceed with HAL. Verify Weave compatibility
  with `claude -p` subprocess calls.

Alternative harnesses to evaluate:

- **SWE-agent** (`SWE-agent/SWE-agent`) — the original agent
  framework from the SWE-bench team. Supports any LLM backend.
  Has its own tool interface (edit, search, bash).
- **sb-cli** (`SWE-bench/sb-cli`) — official SWE-bench CLI for
  running evaluations. Lightweight alternative to the full HAL
  harness.

**Timeout**: 30 minutes per task for both conditions. This is
generous enough to accommodate Plankton's ~3x overhead (observed in
ClassEval) without disproportionately penalizing either condition.
Use a single timeout for both — differential timeouts would be a
confound. Tasks exceeding 30 minutes are recorded as failures.

**Isolation**: HAL harness provides per-task filesystem isolation
natively — each task runs in `/tmp/agent_run_<uuid>/` with its own
copy of the agent code and inputs. Claude Code's `--worktree` flag
is redundant under HAL and is not used. For manual execution (cheat
sheet below), use separate `git clone` per task.

**Parallelism**: Use HAL's `--max_concurrent N` flag for task-level
parallelism. N tasks run simultaneously, each in its own isolated
temp directory. Within each task, baseline and Plankton conditions
run **sequentially** (not in parallel) to ensure both conditions get
identical API conditions — this eliminates API fairness confounds
(rate-limit asymmetry between conditions). The randomized A/B coin
flip per task is preserved. N is determined by the concurrency probe
(Phase 0 Step 10). SWE-bench sets `requires_sandbox = False`, so
Docker is not required for parallel execution.

> **Why not condition-level parallelism?** Running baseline and
> Plankton in parallel for the same task would require two
> concurrent API sessions competing for the same rate-limit quota.
> If one gets rate-limited and the other doesn't, their timeout
> budgets become unequal — an unmeasured confound that could flip
> pass/fail outcomes. Task-level parallelism avoids this entirely.

**Sandboxing**: Run on host for the 50-task pilot. SWE-bench tasks
edit real Python repos — the primary risk is test execution, not
the edits. For the pilot under close observation, host execution is
acceptable and avoids the complexity of injecting Plankton hooks
into Docker containers. Move to Docker if scaling to SWE-bench
Verified (500 tasks).

**Prompt**: The SWE-bench task prompt is the GitHub issue description
itself — no custom prompt template needed. Both conditions receive
the same issue text. The only variable is whether Plankton hooks
are active.

**Tool budget**: Both conditions use
`--disallowedTools WebFetch,WebSearch,Task` to prevent solution
lookup. All other tools (Edit, Read, Write, Bash, Glob, Grep) are
available in both conditions equally.

> **Note**: `--allowedTools` (allowlist) may be silently ignored when
> combined with `--dangerously-skip-permissions` (see Implementation
> Log). Use `--disallowedTools` (blocklist) as the safer approach.
>
> - **Finding** [HIGH]: GH #563, #1498, #17577, #19429 confirm
> `--dangerously-skip-permissions` overrides `--allowedTools`.
> Docs recommend `--disallowedTools`. **Recommendation**: Use
> `--disallowedTools WebFetch,WebSearch,Task` only; remove all
> `--allowedTools` references from the protocol.

**Condition setup**:

| Condition | Settings |
| --- | --- |
| **A (baseline)** | `cc -bare` — no hooks, settings, MCPs, or commands |
| **B (plankton)** | Hooks enabled, `.claude/hooks/` + linter configs injected |

**Runner shape (per task)** (shown as baseline-first; actual order
determined by per-task coin flip — see Task ordering above):

1. **Setup**: HAL harness checks out the repo at the relevant commit.
   For the Plankton condition, copy `.claude/hooks/` and linter
   configs into the task repo.
2. **Baseline**: Run `cc -bare -p` with the issue prompt. No hooks.
3. **Reset**: `git checkout . && git clean -fd` — restore the repo to
   its original state before running the Plankton condition. Do not
   assume the harness provides this isolation.
4. **Plankton**: Run `claude -p` with the issue prompt. Hooks fire
   on every Edit/Write.
5. **Collect**: Extract the git diff (patch) from the modified repo.
6. **Score**: HAL harness applies the patch in Docker and runs
   FAIL_TO_PASS + PASS_TO_PASS tests. Binary pass/fail per task.

The metric is a single **resolve rate** per condition (percentage
of tasks where both FAIL_TO_PASS and PASS_TO_PASS tests pass).
Delta = Plankton resolve rate minus baseline resolve rate.

### Prerequisites (Phase 0)

Before running any benchmark, complete every step below. Each step
includes a verification command — do not proceed until it passes.

#### Step 1: Confirm Claude Code version

```bash
claude -v
# Expected: 2.1.50 or newer
```

Record the exact version — it goes into results metadata.

#### Step 2: Confirm `cc -bare` alias and bare-settings.json

```bash
cat ~/.claude/bare-settings.json
# Expected: {"disableAllHooks": true}

type cc | grep -q '\-bare' && echo "OK: cc -bare defined"
```

#### Step 3: Verify hooks and linter configs

```bash
cd /path/to/plankton
ls .claude/hooks/*.sh && echo "OK: hooks present"
ls .ruff.toml ty.toml 2>/dev/null && echo "OK: linter configs present"
```

#### Step 4: Verify baseline has zero hook activity

```bash
TASK_DIR=$(mktemp -d) && cd "$TASK_DIR" && git init --quiet
echo "def foo(): pass" > solution.py && git add . && git commit -qm init
cc -bare -p --output-format json --dangerously-skip-permissions \
  "Edit solution.py to add a comment '# test'" 2>&1 | tee /tmp/bare-test.json
# Inspect output: there should be zero PostToolUse hook invocations
rm -rf "$TASK_DIR"
```

#### Step 5: Rename CLAUDE.md

```bash
cd /path/to/plankton
mv CLAUDE.md CLAUDE.md.bak
```

#### Step 6: Verify `claude -p` subprocess behavior

Two confirmed bugs in `claude -p` affect harness use. Verify workarounds
before any automated run.

**Bug 1 — TTY hang** ([GH #9026](https://github.com/anthropics/claude-code/issues/9026)):
`claude -p` hangs indefinitely when spawned as a subprocess without a
pseudo-terminal (CI, Docker, Python `subprocess.run`). Workaround:

```bash
# Verify: this should complete, not hang
echo "say hi" | script -q /dev/null claude -p 'say hi'
# If that fails, try:
echo "say hi" | unbuffer claude -p 'say hi'
```

Add the working wrapper to the agent script. Closed as "not planned".

**Bug 2 — Large stdin silent failure** ([GH #7263](https://github.com/anthropics/claude-code/issues/7263)):
`claude -p` silently returns empty stdout (exit 0) when the prompt
exceeds ~7,000 characters. SWE-bench issue descriptions regularly exceed
this. Workaround: write the prompt to a temp file.

```bash
# Bad (may fail silently on large issues):
claude -p "$(cat issue_description.txt)"

# Good (pipe via stdin to avoid shell argument expansion limits):
cat issue_description.txt | claude -p -
```

Verify by passing a >7,000-character prompt via stdin and confirming
non-empty output. Closed as "not planned".

> **Resolved**: Does `claude -p -` read from stdin? If not,
> investigate `--file` flag or other alternatives. For automated runs
> via HAL harness, the prompt is passed as a function argument, not
> via shell — this workaround applies only to manual/script execution.
>
> - **Finding** [HIGH]: Confirmed — `claude -p` reads stdin via piping
>   (`cat file | claude -p`); `-` is supported per CLI docs. No
>   `--prompt-file` flag exists; only `--system-prompt-file` does.
>   Use `cat issue_description.txt | claude -p` for script execution.
>   Resolved.

#### Step 7: Install evaluation harness

**HAL harness** (recommended for automated 50-task run — supports custom
agent callables with cost tracking):

```bash
pip install hal-harness  # or clone princeton-pli/hal-harness
hal-eval --help
```

**sb-cli** (recommended fallback — lightweight patch evaluator, no custom
agent API needed; pair with a manual runner script):

```bash
pip install sb-cli
sb --help
```

> **Note on SWE-agent**: SWE-agent is an *agent framework*, not an
> evaluation harness for arbitrary agents. It has its own tool interface
> (edit, search, bash) implemented as self-contained tool bundles with
> executables in `bin/` folders. All three agent types (DefaultAgent,
> RetryAgent, ShellAgent) use SWE-agent's internal tool registries
> (e.g., `tools/edit_anthropic`). There is no passthrough or delegation
> mode — the docs do not support routing tool calls to an external
> agent like Claude Code. Using SWE-agent as the harness would route
> execution through SWE-agent's tools, bypassing Claude Code's Edit/Write
> tools and preventing Plankton hooks from firing. Do not use SWE-agent
> as the evaluation harness. Use HAL harness or sb-cli instead.
> ([Verified 2026-02-23](https://swe-agent.com/latest/) against agent
> config and tools config documentation.)

Record versions of all tools in results metadata.

#### Step 8: Verify subprocess permission fix ([spec](subprocess-permission-gap.md))

The Plankton subprocess permission gap has been resolved (2026-02-23).
Empirical testing showed shell-spawned subprocesses DO inherit
`bypassPermissions` from the parent session (P0), and the fix
(`--dangerously-skip-permissions` + `--disallowedTools`) was applied
anyway for explicit safety. Verify the fix is in place:

```bash
cd /path/to/plankton
grep -q 'dangerously-skip-permissions' .claude/hooks/multi_linter.sh \
  && echo "OK: subprocess permission fix present"
grep -q 'disallowedTools' .claude/hooks/multi_linter.sh \
  && echo "OK: tool restriction present"
ls .claude/subprocess-settings.json 2>/dev/null \
  && echo "OK: subprocess settings file present"
```

#### Step 9: Verify tool restriction enforcement

```bash
# Run a test task with the blocklist and confirm WebSearch is blocked.
TASK_DIR=$(mktemp -d) && cd "$TASK_DIR" && git init --quiet
echo "def foo(): pass" > solution.py && git add . && git commit -qm init
claude -p --output-format json --dangerously-skip-permissions \
  --disallowedTools WebFetch,WebSearch,Task \
  "Try to use WebSearch to find something, then edit solution.py to add a comment" \
  2>&1 | tee /tmp/tool-test.json
# Inspect: WebSearch should not appear in tool_use events
rm -rf "$TASK_DIR"
```

#### Step 10: Concurrency probe (determine max parallel tasks)

Run an escalating concurrency test to determine the maximum safe
parallelism for your API tier. Use trivial `claude -p` tasks to
avoid wasting budget:

```bash
# Test with N=1, 2, 4, 8 concurrent trivial tasks
for N in 1 2 4 8; do
  echo "=== Testing N=$N concurrent tasks ==="
  START=$(date +%s)
  for i in $(seq 1 $N); do
    TASK_DIR=$(mktemp -d)
    cd "$TASK_DIR" && git init --quiet
    echo "def foo(): pass" > solution.py && git add . && git commit -qm init
    claude -p --output-format json --dangerously-skip-permissions \
      "Edit solution.py to add a docstring to foo" > /dev/null 2>&1 &
  done
  wait
  END=$(date +%s)
  echo "N=$N completed in $((END - START))s"
  # Check for 429 errors in Claude Code logs if available
done
```

Find the knee: the N where completion time stops scaling linearly
or 429 errors appear. Record max safe N in results metadata. This
value is used as `--max_concurrent` in the HAL harness invocation.

#### Step 11: Archive previous benchmark infrastructure

```bash
mkdir -p benchmark/archive
mv benchmark/*.py benchmark/*.txt benchmark/*.json benchmark/archive/ 2>/dev/null
mkdir -p benchmark/swebench/results
```

#### Prerequisites checklist

- [ ] Claude Code version recorded (`claude -v`)
- [ ] `cc -bare` alias loads and expands correctly
- [ ] `~/.claude/bare-settings.json` contains `{"disableAllHooks": true}`
- [ ] `.claude/hooks/` and linter configs present
- [ ] Baseline (`cc -bare -p`) produces zero hook activity
- [ ] `CLAUDE.md` renamed to `CLAUDE.md.bak`
- [ ] TTY hang workaround verified (`script -q` or `unbuffer`)
- [ ] Large stdin workaround verified (file-based prompt, >7K chars)
- [ ] Tool restriction enforced: `--disallowedTools WebFetch,WebSearch,Task`
- [ ] HAL harness (or sb-cli) installed and version recorded
- [ ] Concurrency probe completed: max safe N recorded in results metadata
- [ ] Subprocess permission fix verified (`--dangerously-skip-permissions` + `--disallowedTools`)
- [ ] Previous benchmark infrastructure archived

### Phase 1: EvalPlus/ClassEval exploration — COMPLETE (archived)

Phase 1 explored text-completion benchmarks (EvalPlus, ClassEval).
Key findings: HumanEval+ tasks too simple, ClassEval pilot showed
+5.3% but with prompt adaptation concerns. This phase identified the
text-completion vs tool-use paradigm mismatch that led to the
SWE-bench pivot. Infrastructure archived to `benchmark/archive/`.
See Implementation Log for full details.

### Phase 2: SWE-bench setup and pilot (~$150-200) — NEXT

#### Step 0: Validation gate (2-task dry run)

Run 2 SWE-bench tasks (1 easy, 1 medium) through the complete
pipeline with both conditions. All 6 criteria must pass before
proceeding to the full 50-task run:

- [ ] Both conditions complete without crash or timeout
- [ ] Patches are non-empty git diffs
- [ ] Plankton condition shows hook activity in logs (PostToolUse events)
- [ ] Evaluation harness accepts both patches and returns pass/fail verdicts
- [ ] A and B produce different patches (confirming conditions differ)
- [ ] Wall clock time and API costs are within expected ranges

Failures trigger investigation, not automatic retry. Do not proceed
until all 6 pass.

#### Mid-run abort criteria

During the full 50-task run, abort early if any threshold is hit:

- **Infrastructure errors**: >20% of completed tasks fail with
  non-task errors (API 5xx, crashes, malformed output). Task-level
  failures (empty patch, tests fail) do NOT count.
- **Consecutive empty patches**: 10 consecutive tasks produce empty
  patches in either condition (indicates systematic harness failure).
- **Sustained rate limiting**: API returns 429 errors for >10 minutes
  continuously despite backoff (indicates tier capacity exceeded).

On abort: save all completed results, investigate root cause, fix,
and resume from the last completed task (do not re-run completed
tasks).

**Steps 1-4:**

1. Install HAL harness (or sb-cli / SWE-agent) and verify tooling
2. Build agent wrapper: thin shell that invokes `claude -p` or
   `cc -bare -p` and returns the git diff as a patch
3. Inject Plankton hooks into task repos for the Plankton condition
4. Run full SWE-bench Verified Mini (50 tasks x 2 conditions)

### Phase 3: Scale up (~$200-500)

1. Run SWE-bench Verified Mini with Sonnet and Opus
2. Run SWE-bench Verified (500 tasks) with best-performing model
3. Optionally add post-hoc linter analysis for secondary metrics
4. Publish results

> **Docker prerequisite for Phase 3**: The full 500-task run should
> move to Docker isolation. Plankton's Phase 3 subprocess spawns
> `claude -p` from within the hook (with `--dangerously-skip-permissions`
> paired with `--disallowedTools`, confirmed working 2026-02-23) — this requires
> Claude CLI to be installed and authenticated inside the Docker
> evaluation container. Document Claude CLI installation in the
> SWE-bench Docker image and API key injection (via env var) before
> starting this phase.

### Phase 4: Feature implementation benchmark (future, optional)

1. Run FeatureBench (200 tasks, 24 Python repos) — tests feature
   implementation, not just bug-fixing
2. Cross-model validation with GLM (see GLM/Z.AI section)

### Null result contingency

If Phase 2 reveals zero or negative effect on SWE-bench Verified Mini:

1. **Investigate**: Analyze Plankton logs — did hooks fire? Did the
   model act on lint feedback? Were violations detected and fixed?
   Check subprocess logs for failures (subprocess permission fix
   confirmed working 2026-02-23; see
   `docs/specs/subprocess-permission-gap.md`).
2. **Interpret**: If hooks fired but didn't help, the lint-fix loop
   may not address the bottleneck for SWE-bench tasks (which may be
   reasoning about the issue rather than code quality).
3. **Pivot**: Try FeatureBench (feature implementation rather than
   bug-fixing) — Plankton may help more with writing new code than
   fixing existing code.
4. **Do not publish**: Null results are investigated and pivoted on,
   not posted.

### Publication decision ladder (pre-registered)

After the full SWE-bench Verified Mini run (50 tasks x 2 conditions),
use the number of discordant pairs (tasks that flip between
conditions) to determine the next step:

| Discordant pairs | Decision |
| --- | --- |
| **12+** | Publish results with McNemar's test, effect size, and CI |
| **6–11** | Scale to SWE-bench Verified (500 tasks) for confirmatory analysis |
| **<6** | Pivot to FeatureBench or investigate whether hooks are firing |

This framework is pre-registered to avoid post-hoc rationalization.
N=50 is a screening run, not a definitive significance test. With
a typical discordant rate of ~22–28%, the effective sample driving
McNemar's test is only ~11–14 pairs — enough to detect a large
effect but not a modest one. 12+ discordant pairs is the minimum
for a credible preliminary result; confirmatory power requires
scaling to 500 tasks.

### Interpreting ambiguous results

If the McNemar's test yields p > 0.05 but the direction is positive
(more fail→pass than pass→fail flips), report:

1. **Effect size**: Odds ratio of discordant pairs (fail→pass / pass→fail)
2. **95% confidence interval**: Exact binomial CI on the discordant
   proportion
3. **Descriptive statistics**: Raw flip counts, percentage delta,
   and per-task breakdown

Do not claim statistical significance. Instead, follow the publication
decision ladder: 6-11 discordant pairs → scale to 500 tasks for
confirmatory power. Report the N=50 result as "directional evidence
pending confirmation" if publishing the scale-up.

If the direction is negative (more pass→fail than fail→pass), this
indicates Plankton may be causing regressions. Investigate hook logs
for the regressed tasks before scaling up.

### Error handling

Tasks that crash, timeout, or produce malformed output must be recorded
as failures in the results, not silently dropped. The runner script
should capture and log all error conditions alongside the pass/fail
verdict.

## Controls and Confounders

- **Claude Code version**: Pin the exact Claude Code version
  (`claude -v`) used for all benchmark runs. Record it in results
  metadata. The `--tools` flag behavior and settings cascade mechanics
  are version-dependent.
- **Model identity drift**: Use fixed model IDs, not "latest" aliases.
  Claude Code can be configured to use a specific model via the `model`
  settings key. Otherwise baseline runs today and Plankton runs next
  week are not comparable because the underlying model changed.
- **Hidden hooks from other scopes**: Hooks can come from user, project,
  local, plugins, skills, agents, and managed policy settings. If
  settings scopes are not locked down, the "baseline" may still have
  hooks firing. Use `--setting-sources` deliberately and keep the
  benchmark repo self-contained.
- **Hooks snapshot behaviour**: Hooks are snapshotted per session. The
  design needs either one Claude Code process per task (simplest) or a
  clean restart between conditions. Do NOT toggle settings files
  mid-session and hope it sticks. Claude Code warns that hook changes
  do not take effect immediately and require review/restart.
- **Tool restriction**: Both conditions use
  `--disallowedTools WebFetch,WebSearch,Task` to prevent solution
  lookup. All other tools (Edit, Read, Write, Bash, Glob, Grep) are
  available in both conditions equally. The blocklist approach is used
  because `--allowedTools` may be silently ignored when combined with
  `--dangerously-skip-permissions` (see Finding in Tool budget section).
- **Agent self-correction**: Both conditions have full code-editing
  tool access, so the agent may run tests and self-correct in both.
  This is by design — the benchmark tests the full product, not
  isolated first-attempt quality.
- **Sandbox / runtime variance**: Execution-based benchmarks are
  sensitive to timeouts, CPU contention, and sandbox differences.
  EvalPlus notes high-variance outcomes on slow machines. Keep the
  execution environment consistent across conditions.
- **Hook script fragility**: Hooks communicate via JSON on stdin/stdout.
  Claude Code warns that shell profile output (e.g. `echo` in
  `.bashrc`) can break JSON parsing for hooks. If Plankton uses JSON
  output to control flow, a clean non-interactive shell environment is
  required.

### Accepted confounders

These are known sources of variance that are **permanently accepted**
by design. The benchmark tests Plankton as a full product — Claude
Code CLI with hooks vs. Claude Code CLI without hooks. We are not
decomposing the signal into component effects (lint feedback vs.
subprocess fixes vs. auto-formatting). Decomposition is a separate
experiment if the product-level A/B shows a meaningful delta.

- **Subprocess delegation asymmetry**: Condition B (Plankton) gets two
  agents writing code — the main agent plus the Phase 3 subprocess
  that autonomously fixes lint violations. Condition A gets one. This
  is accepted because subprocess delegation is integral to the Plankton
  user experience.
- **Dynamic subprocess model routing**: Plankton selects haiku, sonnet,
  or opus for subprocess delegation based on violation complexity. This
  adds variance to the Plankton condition that baseline does not have.
  Accepted for product fidelity — this is how Plankton actually works.
- **Non-deterministic generation**: Claude Code CLI defaults are used
  (temperature > 0). Non-determinism is handled by the paired design
  and sample size rather than by forcing greedy decoding.

## Reporting and Statistical Analysis

### Minimum artefacts to record (per task)

- **Benchmark version info**: git SHAs (dataset + runner + Plankton),
  plus Claude Code version (`claude -v`). Aider's harness treats commit
  hashes as essential provenance for reproducibility.
- **Exact prompt template** (version-controlled), plus exact CLI
  invocation used (including `--settings`, `--setting-sources`).
- **Output JSON** from `--output-format json`, which includes
  `session_id` and metadata (and can include usage).
- **Test outputs** and the final pass/fail verdict per task.
- **Hook artefacts**: hooks receive `transcript_path` and other session
  fields via stdin. Capture transcripts and/or Plankton's own logs so
  the report can show what feedback happened in the Plankton condition.

### Statistical analysis

Because the same tasks are run in both conditions, outcomes are paired
binary data (each task is pass/fail under baseline and pass/fail under
Plankton). Treat them as paired, not independent. A standard test for
paired proportions is McNemar's test (and there are better-behaved
variants like the mid-p approach).

**Power considerations**: N=50 is a preliminary screening run, not
a definitive significance test. With a typical discordant rate of
~22–28%, the effective sample driving McNemar's test is only ~11–14
pairs. Achieving 80% power at p<0.05 requires approximately 144
total paired observations — far beyond what 50 tasks can provide.
A clear signal at N=50 (12+ discordant pairs, heavily skewed
toward Plankton) is sufficient for preliminary publication; confirmatory
power requires scaling to SWE-bench Verified (500 tasks) in Phase 3.

**Reporting discordant pair direction**: Report both flip directions
separately — fail→pass with Plankton (positive) and pass→fail with
Plankton (regressions). Example: "14 discordant pairs: 11 fail→pass,
3 pass→fail." McNemar's test uses the total count, but the narrative
must show the direction breakdown so readers can assess regression
risk.

What would count as convincing:

- A clear delta in pass rate between conditions — tasks flip from
  fail to pass more often than pass to fail (the paired perspective).
- A sensible qualitative story in Plankton logs (e.g. lint feedback
  caught an issue, the model or subprocess corrected it, tests then
  passed).
- Consistency across models — if the effect appears with Haiku but
  disappears with Opus, the signal may be model-dependent rather
  than a product property.

### Publication format

Results will be published as X (Twitter) posts with comparison
visualizations (e.g., pass-rate bar charts, before/after tables).
Only publish if a meaningful benefit is found — null results are
investigated and pivoted on, not posted.

## Cost Estimate

| Phase | Tasks | Est. Cost | Notes |
| --- | --- | --- | --- |
| Phase 1 (EvalPlus/ClassEval, archived) | ~50 | ~$15 (spent) | Single-turn |
| Phase 2 (SWE-bench Mini, Haiku) | 100 | ~$150-200 | ~$1.5-2/task; ~12h N=4 |
| Phase 3 (SWE-bench Verified 500, multi-model) | ~3,000 | ~$500-1,500 | |
| Phase 4 (FeatureBench + GLM) | ~800 calls | ~$200-500 | |

> **Phase 2 cost note**: The subprocess permission fix is confirmed
> working (2026-02-23). Expect ~$1.5-2/task for the Plankton condition
> due to Phase 3 subprocess API calls. Baseline remains ~$1/task.

## Data Retention

Raw benchmark artefacts are stored under `benchmark/swebench/results/`:

| Artefact | Format | Retention |
| --- | --- | --- |
| Per-task results | JSONL (one line per task per condition) | Permanent |
| Patches | `.patch` files (git diff output) | Permanent (in repo) |
| Agent transcripts | JSON (from `--output-format json`) | Permanent (in repo) |
| Hook logs | Plankton PostToolUse event logs | Permanent (in repo) |
| Run metadata | JSON (versions, seed, timestamps, costs) | Permanent |

All raw data accompanies any publication for reproducibility. The
`results/` directory is `.gitignore`d during development but committed
after each completed benchmark phase.

## Manual Execution Cheat Sheet

### Single-task A/B test (SWE-bench)

```bash
# 1. Pick a SWE-bench task and check out the repo at the right commit
#    (HAL harness or sb-cli handles this automatically)

# 2. Condition A: Baseline (no hooks)
cd /path/to/task-repo
cat issue_description.txt | cc -bare -p --output-format json \
  --dangerously-skip-permissions \
  --disallowedTools WebFetch,WebSearch,Task \
  --model claude-haiku-4-5-20251001
git diff > baseline.patch

# 3. Reset repo, inject hooks for condition B
git checkout .
cp -r /path/to/plankton/.claude/hooks/ .claude/hooks/
cp /path/to/plankton/.ruff.toml /path/to/plankton/ty.toml .

# 4. Condition B: Plankton (hooks active)
cat issue_description.txt | claude -p --output-format json \
  --dangerously-skip-permissions \
  --disallowedTools WebFetch,WebSearch,Task \
  --model claude-haiku-4-5-20251001
git diff > plankton.patch

# 5. Evaluate both patches via SWE-bench harness
```

### Automated execution (HAL harness)

```bash
# Full SWE-bench Verified Mini run (50 tasks x 2 conditions)
# N determined by concurrency probe (Phase 0 Step 10)
hal-eval --benchmark swebench_verified_mini \
  --agent_dir ./benchmark/swebench/agent \
  --agent_function solve \
  --max_concurrent 4
```

The agent wrapper function handles condition switching (baseline vs
Plankton) per task and returns patches for evaluation. HAL provides
per-task filesystem isolation (`/tmp/agent_run_<uuid>/`); the
`--max_concurrent` flag controls task-level parallelism via
`asyncio.Semaphore`. Weave cost tracking works correctly with
parallel execution — all tasks share the same `run_id` and are
tagged by `weave_task_id`.

## Implementation Log

### 2026-02-22: Phase 0 + 1 scaffolding

Implemented the benchmark runner infrastructure under `benchmark/`:

```text
benchmark/
├── prereqs.sh                    # Phase 0 prerequisites checker (8 checks)
├── runner.py                     # A/B benchmark runner (EvalPlus + ClassEval)
├── analyze.py                    # Post-benchmark reporting and statistical analysis
├── evalplus_wrapper.py           # macOS setrlimit crash workaround
├── classeval_wrapper.py          # ClassEval unittest evaluation wrapper
├── prompt_template.txt           # EvalPlus prompt (version-controlled)
├── classeval_prompt_template.txt # ClassEval prompt (version-controlled)
├── ClassEval_data.json           # ClassEval dataset (100 tasks, downloaded)
└── results/                      # Created at runtime
    ├── samples/                  # JSONL files (baseline.jsonl, plankton.jsonl)
    └── logs/                     # Per-task JSON metadata
```

**Prerequisites verified** (via `bash benchmark/prereqs.sh`):

- Claude Code 2.1.50, `cc -bare` alias, `bare-settings.json`,
  `--worktree` support, EvalPlus 0.3.1

**Pipeline validated** (1-task and 3-task runs):

- Baseline: ~10-17s per task, generates clean function bodies
- Plankton: ~32-57s per task, hooks fire and influence output
  (module docstrings, type hint cleanup observed)
- Both conditions produce valid EvalPlus JSONL
- Partial runs (`--tasks N`) skip evalplus evaluation (requires
  all 164 tasks); full runs invoke evalplus automatically

**Operational issues encountered and resolved**:

1. `prereqs.sh` runs in bash but `cc` is a zsh function — changed
   check to grep `~/.zshrc` instead of `type cc`
2. EvalPlus evaluator needs venv Python, not system `python3` —
   prereqs now checks `.venv/bin/python` first
3. `pyproject.toml` missing `[tool.hatch.build.targets.wheel]` —
   added `packages = ["src/app"]` to unblock `uv add`
4. `claude -p` refuses nested sessions — runner unsets `CLAUDECODE`
   env var before invoking subprocess
5. `claude -p` default permission mode blocks Edit — added
   `--dangerously-skip-permissions` to both conditions
6. EvalPlus `resource.setrlimit` crashes on macOS (both `RLIMIT_AS`
   and `RLIMIT_DATA`) — `evalplus_wrapper.py` monkeypatches
   `setrlimit` to silently catch `ValueError`
7. EvalPlus asserts all 164 tasks present — partial validation runs
   now skip evaluation and report JSONL generation only

**Usage**:

```bash
# Check prerequisites
bash benchmark/prereqs.sh

# Rename CLAUDE.md (neither condition should see project instructions)
mv CLAUDE.md CLAUDE.md.bak

# Validation run (3 tasks x 2 conditions, ~2 min)
.venv/bin/python benchmark/runner.py --tasks 3 --mini

# Full Phase 2 run (164 tasks x 2 conditions)
.venv/bin/python benchmark/runner.py --mini
```

### 2026-02-22: Plankton condition — repo-root strategy

**Problem**: Initial design copied `.claude/hooks/` and linter configs
into a temp directory per task. This was fragile (had to maintain a
`LINTER_CONFIGS` list) and risked missing config files.

**Resolution**: Plankton condition now runs `claude -p` directly from
`REPO_ROOT`. The stub `solution.py` is written into the repo root,
hooks fire naturally from `.claude/hooks/`, and cleanup removes only
the stub file. No copies, no config list, no worktrees.

Baseline condition remains unchanged (temp dir, no hooks).

**Also clarified**: The `CLAUDECODE` env var unset (issue #4 above) is
only needed when the runner itself is invoked from inside Claude Code.
When run from a normal terminal, `claude -p` works without it. The
unset is kept as a defensive measure.

**Removed**: `--worktree` flag from `_build_cmd` — per-task worktree
isolation is unnecessary since tasks run sequentially and the plankton
stub is cleaned up after each task.

### 2026-02-22: Manual execution as primary method

**Context**: The automated `runner.py` was built to solve operational
issues encountered during validation (CLAUDECODE env var, permission
flags, macOS setrlimit crashes). These fixes remain valuable, but the
user's intent is simpler: run `claude -p` vs `cc -bare -p`.

**Changes**:

- Added "Manual Execution Cheat Sheet" section with exact commands
  for both conditions, evaluation, and optional interactive verification
- Updated "Runner shape" section to reflect repo-root strategy
  (removed stale `--worktree` and copy-fallback references)
- `runner.py` repositioned as optional automation, not required
- Added cleanup step to prerequisites (clear `benchmark/results/`
  before real runs to avoid contamination from validation data)

**Key insight confirmed**: `claude -p` fires hooks identically to
interactive mode. Validated during Phase 1 — plankton condition took
32-57s per task (vs 10-17s baseline) with observable hook effects.
Using `-p` is standard practice for coding benchmarks and ensures
reproducibility by removing human intervention as a confounder.

### 2026-02-23: ClassEval benchmark support

**Context**: HumanEval+ tasks (10-20 line single functions) proved too
simple for Plankton's lint-fix loop to produce measurable correctness
differences. 8 completed tasks showed identical algorithms across
conditions. Per the null result contingency plan, pivoted to ClassEval
(100 class-level tasks, ~50-100 lines each, method dependencies).

**Implementation**: Extended `runner.py` with `--benchmark {evalplus,classeval}`
flag. ClassEval tasks use a separate prompt template, skeleton writer,
and JSONL format (`predict` key instead of `completion`). Added:

- `get_classeval_tasks()` — loads `ClassEval_data.json`, returns
  `dict[str, dict]` keyed by task_id
- `write_class_skeleton()` — writes `import_statement + skeleton`
  to `solution.py`
- `append_classeval_jsonl()` — writes `{"task_id": ..., "predict": [code]}`
- `classeval_wrapper.py` — evaluation wrapper that concatenates
  prediction + test code and runs unittest with 5s timeout per task
- `classeval_prompt_template.txt` — "Edit solution.py to implement
  all methods in the class"
- `analyze.py` updated with `_CLASSEVAL_TASK_ID_RE` and
  benchmark-aware `validate_jsonl()`

**Data quirk**: `import_statement` in `ClassEval_data.json` is a list
of strings, not a single string. Both `write_class_skeleton()` and
`classeval_wrapper.py` handle both types defensively.

**Evaluation quirk**: ClassEval tests use `unittest.TestCase`. Running
them via `python -m pytest` or `python -m unittest <tmpfile>` fails
because unittest's module loader cannot import temp files by path.
The working approach is `python <tmpfile>` with a
`if __name__ == '__main__': unittest.main()` footer appended to the
test source.

**Test coverage**: 46 unit tests covering all new functions
(`tests/unit/test_runner.py`, `tests/unit/test_analyze.py`,
`tests/unit/test_benchmark_integration.py`).

**Usage**:

```bash
# Dry run (verify commands, no API calls)
.venv/bin/python benchmark/runner.py --benchmark classeval --tasks 2 --dry-run

# 20-task pilot run
.venv/bin/python benchmark/runner.py --benchmark classeval --tasks 20 --timeout 300 --skip-eval

# Full 100-task run (not yet executed)
.venv/bin/python benchmark/runner.py --benchmark classeval --timeout 600
```

### 2026-02-23: Subprocess permission gap (critical)

**Problem**: The Plankton Phase 3 subprocess (`multi_linter.sh:403`)
spawns `claude -p` without `--dangerously-skip-permissions`. Research
confirms child processes do not inherit the parent's permission bypass.
During benchmark runs, the subprocess may be silently failing on
permission prompts, meaning Phase 3 fixes never apply.

**Impact**: The pilot's +5.3% delta may come entirely from lint
feedback influencing the main agent, not from successful subprocess
fixes. This is also a production issue for headless/CI workflows.

**Status**: Separate issue document created at
`docs/specs/subprocess-permission-gap.md`. Must be resolved before
the full 100-task run.

**Resolution** (2026-02-23): Empirical testing (P0) showed the
original bug was NOT reproduced — shell-spawned subprocesses DO
inherit `bypassPermissions` from the parent session. The fix was
applied anyway (explicit > implicit): `--dangerously-skip-permissions`
paired with `--disallowedTools` blacklist derived per tier, observable stderr
logging, settings migrated from `~/no-hooks-settings.json` to
project-local `.claude/subprocess-settings.json` (auto-created).
All 278 unit assertions pass, all empirical tests pass. The pilot's
+5.3% delta likely included working subprocess fixes, not just lint
feedback. See subprocess-permission-gap.md for full details.

### 2026-02-23: Tool restriction (--disallowedTools)

**Problem**: Both conditions had WebFetch and WebSearch in their
available tools list. While no actual invocations were detected in
log analysis, the availability of web tools is a benchmark integrity
concern — the model could look up solutions online.

**Investigation**: Initially considered switching to `--allowedTools`
(allowlist) for stricter control. Fact-checking revealed
`--dangerously-skip-permissions` silently overrides `--allowedTools`
(GH #563, #1498, #17577, #19429). The `--allowedTools` approach was
abandoned.

**Resolution**: Use `--disallowedTools WebFetch,WebSearch,Task`
(blocklist) for both conditions. This works correctly under
`--dangerously-skip-permissions` and blocks web search, web fetch,
and subprocess spawning while leaving all other tools available.
Step 9 in Prerequisites verifies enforcement empirically.

### 2026-02-23: ClassEval 20-task pilot results

Ran 20 ClassEval tasks (ClassEval_0 through ClassEval_26, first 20
by sorted task_id) with `claude-haiku-4-5-20251001`, timeout 300s.
One plankton task timed out (ClassEval_17, 300s). Results exclude
the timed-out task (19 paired tasks):

| Metric | Baseline | Plankton |
| --- | --- | --- |
| Class-level pass@1 | 8/19 (42.1%) | 9/19 (47.4%) |
| Method-level tests | 351/382 (91.9%) | 361/382 (94.5%) |
| Avg time (success) | 37.2s | 117.2s |
| Timeouts | 0 | 1 |
| Web tool invocations | 0 | 0 |

**Key observations**:

- Plankton flipped one class from fail to pass (ClassEval_20:
  19/22 → 22/22) and gained 10 additional method-level test passes
  across the board.
- ~3x time overhead from hooks is consistent with EvalPlus
  observations (32-57s vs 10-17s).
- Default timeout of 120s is insufficient for ClassEval with
  plankton hooks. Bumped default to 300s; recommend 600s for full
  runs.
- Sample size (19 paired tasks) is too small for McNemar's test
  significance. Full 100-task run needed for statistical power.

### 2026-02-23: Pivot from text-completion to tool-use benchmarks

**Problem**: Clarification review identified a fundamental paradigm
mismatch. All benchmarks used so far (EvalPlus, ClassEval) are
text-completion benchmarks — models output code as text, no tools
involved. Plankton hooks fire on Edit/Write tool use. To make hooks
fire, the prompt was adapted ("Edit solution.py..." instead of
"Complete this function..."), which changes the task and reduces
scientific validity.

**Research findings**: Tool-use agent benchmarks exist where agents
naturally edit files: SWE-bench, IDE-Bench, FeatureBench. SWE-bench
Verified Mini (50 tasks) has a public HAL leaderboard, costs
~$100-150 for a full A/B, and 51.7% of agent trajectories hit lint
errors — exactly Plankton's domain.

**Decision**: Pivot to SWE-bench Verified Mini as the primary
benchmark. Archive EvalPlus/ClassEval infrastructure. The claim
shifts from "Plankton improves code generation" to "Plankton
improves code editing/bug-fixing by catching lint errors that waste
agent turns" — a stronger and more honest claim that matches real
Plankton usage.

**Actions**:

- Archive `benchmark/` to `benchmark/archive/`
- Build new SWE-bench agent wrapper under `benchmark/swebench/`
- Update ADR: decisions, phases, prerequisites, cost estimates
- ClassEval pilot data retained in Implementation Log as historical
  context

### 2026-02-23: SWE-agent passthrough investigation

**Question**: Can SWE-agent delegate task execution to Claude Code
(passthrough mode), allowing it to serve as the harness while Claude
Code uses its native Edit/Write tools?

**Finding**: No. SWE-agent's official documentation confirms all three
agent types (DefaultAgent, RetryAgent, ShellAgent) use SWE-agent's
internal tool bundles — self-contained executables in `bin/` folders
with registries like `tools/edit_anthropic`. No passthrough, delegation,
or external-agent mode is documented. A custom tool bundle that shells
out to `claude -p` is theoretically possible but undocumented and would
still wrap Claude Code inside SWE-agent's tool interface rather than
letting Claude Code use its native tools (which is what Plankton hooks
require).

**Sources**: [Agent config reference](https://swe-agent.com/latest/reference/agent_config/),
[Tools config](https://swe-agent.com/latest/config/tools/).

**Conclusion**: ADR's decision to use HAL harness (or sb-cli) instead
of SWE-agent is validated. No changes needed.

### 2026-02-23: Clarification review — operational resilience and data handling

**Context**: Second `/spec:clarify` pass focused on dimensions not
covered by the first review (which addressed parallelism, dry runs,
and concurrency). This pass covered document structure, implementation
log hygiene, subprocess degraded mode, data retention, step
consolidation, cost accuracy, abort criteria, and statistical
interpretation.

**Amendments applied**:

1. **Degraded-mode plan**: Added "Degraded mode (subprocess gap
   unresolved)" subsection under Accepted Confounders. Documents
   detection-only mode when subprocess permission gap is unresolved.
   (Subsequently removed 2026-02-23 after subprocess gap resolved —
   see Implementation Log entry "Subprocess permission gap".)
2. **Data Retention section**: Added artefact table (JSONL, patches,
   transcripts, hook logs, metadata) with retention policy.
3. **Step consolidation**: Merged Phase 2 Steps 4-5 (pilot, hook
   verification) into Step 0 Validation Gate. Renumbered to Steps 1-4.
4. **Mid-run abort criteria**: Added three thresholds (>20%
   infrastructure errors, 10 consecutive empty patches, sustained
   429 errors) with resume-from-last-completed protocol.
5. **Ambiguous result interpretation**: Added guidance for p > 0.05
   results: report effect size (odds ratio), 95% CI, descriptive
   stats. Negative direction triggers regression investigation.
6. **Cost estimate updated**: Clarified ~$1/task for main agent only;
   ~$1.5-2/task with subprocess fixes; unchanged in degraded mode.
7. **Implementation Log correction**: Added correction note to stale
   "Tool restriction (--allowedTools)" entry — approach was reversed
   after fact-check confirmed `--dangerously-skip-permissions`
   overrides `--allowedTools`.
8. **Step 9 updated**: Tool restriction verification now tests
   `--disallowedTools` (blocklist) instead of `--allowedTools`
   (allowlist), matching the rest of the protocol.

## GLM/Z.AI Model Support

See [ADR: GLM/Z.AI Model Support for Benchmarking](../adr-glm-benchmark-support.md)
for cross-model validation with GLM via the Z.AI Anthropic-compatible
API. This tests whether Plankton's write-time enforcement generalizes
beyond Claude models.

## References

### Primary (tool-use agent benchmarks)

- [SWE-bench](https://www.swebench.com) — bug-fixing in real Python repos
- [SWE-bench Verified Mini leaderboard (HAL)](https://hal.cs.princeton.edu/swebench_verified_mini)
- [HAL harness](https://github.com/princeton-pli/hal-harness) — Princeton eval framework
- [SWE-agent](https://github.com/SWE-agent/SWE-agent) — agent framework from SWE-bench
- [sb-cli](https://github.com/SWE-bench/sb-cli) — official SWE-bench CLI
- [FeatureBench](https://arxiv.org/abs/2602.10975) — feature implementation benchmark
- [IDE-Bench paper on arXiv](https://arxiv.org/abs/2601.20886) — IDE agent evaluation

### Secondary (text-completion benchmarks, archived)

- [EvalPlus benchmarks](https://evalplus.github.io)
- [ClassEval GitHub repository](https://github.com/FudanSELab/ClassEval)
- [Aider Polyglot benchmark](https://aider.chat/docs/leaderboards/)
- [BigCodeBench GitHub repository](https://github.com/bigcode-project/bigcodebench)

### Leaderboards and other references

- [Scale SEAL leaderboard](https://scale.com/leaderboard)
- [Vellum LLM leaderboard](https://www.vellum.ai/llm-leaderboard)
- [Artificial Analysis intelligence benchmarking](https://artificialanalysis.ai/methodology/intelligence-benchmarking)
- [Arena.ai code leaderboard](https://arena.ai/leaderboard/code)
- [MultiPL-E dataset on Hugging Face](https://huggingface.co/datasets/nuprl/MultiPL-E)
- [Terminal-Bench paper on arXiv](https://arxiv.org/abs/2601.11868)
- [CodeCriticBench paper on arXiv](https://arxiv.org/abs/2502.16614)

### Implementation research findings

- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
- [HAL harness benchmarks README](https://github.com/princeton-pli/hal-harness/blob/main/hal/benchmarks/README.md)
- [GH #19429: --dangerously-skip-permissions overrides --permission-mode plan](https://github.com/anthropics/claude-code/issues/19429)
- [GH #563: --allowedTools not working reliably](https://github.com/anthropics/claude-code/issues/563)
- [GH #11652: Plugin not found with --setting-sources ''](https://github.com/anthropics/claude-code/issues/11652)
- [GH #11872: --setting-source local still loads enterprise managed policies](https://github.com/anthropics/claude-code/issues/11872)
- [Claude Code SDK --setting-sources flag issue](https://github.com/anthropics/claude-agent-sdk-python/issues/186)

### Fact-check sources

- [NCSS PASS McNemar Test Sample Size Documentation](https://www.ncss.com/wp-content/themes/ncss/pdf/Procedures/PASS/Tests_for_Two_Correlated_Proportions-McNemar_Test.pdf)
- [OpenAI: Introducing SWE-bench Verified](https://openai.com/index/introducing-swe-bench-verified/)
- [SWE-agent NeurIPS 2024 Paper](https://arxiv.org/pdf/2405.15793)
- [Aider Polyglot Benchmark](https://aider.chat/2024/12/21/polyglot.html)
- [SWE-bench Verified difficulty breakdown analysis](https://jatinganhotra.dev/blog/swe-agents/2025/04/15/swe-bench-verified-easy-medium-hard.html)
