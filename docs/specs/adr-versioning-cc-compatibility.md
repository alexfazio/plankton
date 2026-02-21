# ADR: Versioning and Claude Code Compatibility Tracking

**Status**: Accepted
**Date**: 2026-02-21
**Author**: alex fazio + Claude Code clarification interview

## Context and Problem Statement

Plankton is an externally distributed hook system for Claude Code. Users
clone or install the repository and depend on the hooks activating correctly
inside their Claude Code sessions. However, there is currently no versioning
scheme for Plankton itself and no mechanism to communicate which Claude Code
versions the hooks have been verified against.

Claude Code hooks have no stable public API. The hook contract — stdin JSON
shape, exit code semantics, matcher behavior, subprocess invocation flags,
settings override mechanisms — is undocumented and can change between any
Claude Code release without notice. Plankton depends on this undocumented
contract across all four hooks (`multi_linter.sh`, `protect_linter_configs.sh`,
`enforce_package_managers.sh`, `stop_config_guardian.sh`). Any Claude Code
update is a potential breaking change.

Without versioning and a tested-version baseline:

1. **Users cannot diagnose compatibility issues.** When hooks misbehave after
   a CC update, there is no reference point to compare against.
2. **The maintainer cannot communicate fixes.** "Plankton now works with CC
   2.2.0" has no meaning without a Plankton version to attach it to.
3. **There is no regression signal.** Without a tested baseline, it is
   impossible to distinguish "CC broke something" from "Plankton introduced
   a bug."

The README previously listed this as an open problem: "need a
strategy for surviving Claude Code CLI updates without breaking."
(Removed during the publication rewrite in commit 668be7f.)

### Scope of the Undocumented Contract

The following Claude Code behaviors are depended upon by Plankton but are not
guaranteed by any published API or changelog:

| Dependency | Used By | Breakage Risk |
| --- | --- | --- |
| PreToolUse stdin: `tool_input.file_path` | All PreToolUse | Medium |
| PreToolUse stdout: `decision` field | protect, enforce | **High**[1] |
| PostToolUse stdin: `tool_input.file_path` | multi_linter | Medium |
| PostToolUse exit codes: 0=silent, 2=stderr | multi_linter | High |
| Stop stdin: `stop_hook_active` bool | stop_guardian | Medium |
| Stop stdout: `decision` field | stop_guardian | Medium |
| `claude -p` with `--settings` flag | multi_linter P3 | High |
| `--model` flag for model selection | multi_linter P3 | Medium |
| `--max-turns` flag for turn limits | multi_linter P3 | Low |
| `disableAllHooks` settings key | `~/.claude/no-hooks-settings.json` | Medium |
| `CLAUDE_PROJECT_DIR` env var set by CC | All hooks | Low |
| Matcher types: `"Edit"`, `"Write"`, `"Bash"` | `.claude/settings.json` | Low |
| `settings.json` hook registration format | All hooks | **High** |

[1] Confirmed deprecated as of 2026-02. The `decision`/`reason` fields are
deprecated for PreToolUse per the
[schema convention ADR](adr-hook-schema-convention.md) (lines 196-204).
The runtime still maps the deprecated values, but official docs now
recommend `hookSpecificOutput.permissionDecision` with `allow|deny|ask`.
This deprecation is the most likely first trigger for a baseline bump.

Any of these could change in a CC release. The versioning system established
by this ADR provides the baseline needed to detect and respond to such changes.

## Decision Drivers

- **External distribution**: Users adopt Plankton by cloning the repo. They
  need to know what they have and whether it works with their CC version.
- **No stable CC hook API**: The hook contract is undocumented. CC updates are
  unpredictable breaking-change vectors.
- **Existing test infrastructure**: A 103-test integration suite exists but is
  not yet CI-ready. Version guarantees must work with manual test execution.
- **Low ceremony**: Plankton is pre-1.0. Process overhead must be minimal so
  releases actually happen.
- **Separation of concerns**: Users need to distinguish "I updated Plankton"
  from "Claude Code updated and something broke."

## Decisions

### D1: Dual Versioning — Plankton Semver + CC Compatibility Baseline

**Decision**: Plankton gets its own semantic version via git tags AND a
separate Claude Code compatibility field. These are independent version axes.

| Axis | Format | Source of Truth | Purpose |
| --- | --- | --- | --- |
| Plankton ver | `v0.x.y` semver | Annotated git tags | Hook changes |
| CC compat | `>= 2.1.50` | config.json + README | Tested CC ver |

**Alternatives considered**:

| Approach | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **Both axes (chosen)** | Clear separation | Two things to maintain | **Yes** |
| **CC stamp only** | Simpler | Cannot communicate Plankton-side fixes | No |
| **Plankton ver only** | Standard semver | Compat implicit, must guess | No |
| **Combined version** | Single number | Couples unrelated change axes | No |

**Rationale**: A user running Plankton v0.2.0 on CC 2.1.50 and another
running Plankton v0.2.0 on CC 2.3.0 have the same Plankton but different
compatibility postures. Without separate axes, communicating "Plankton v0.3.0
fixes compatibility with CC 2.3.0" vs "Plankton v0.3.0 adds Go support"
would be ambiguous.

### D2: Initial Version — v0.1.0 (Pre-Release)

**Decision**: Start at v0.1.0 to signal that the hook contract is still
evolving. The v0.x series makes no backwards-compatibility promise.

**Bump strategy**:

| Change Type | Version Bump | Example |
| --- | --- | --- |
| Bug fixes, minor tweaks | Patch (v0.1.x) | v0.1.0 -> v0.1.1 |
| Breaking config/hook changes | Minor (v0.x.0) | v0.1.0 -> v0.2.0 |
| Hook contract stabilized | Major (v1.0.0) | v0.x.y -> v1.0.0 |

**Alternatives considered**:

| Version | Signal | Verdict |
| --- | --- | --- |
| **v0.1.0 (chosen)** | Pre-release, expect changes | **Yes** |
| v1.0.0 | Stable, backwards-compat expected | Premature |
| v0.9.0 | Near-stable, almost ready | Misleading |

**Rationale**: The hook system works and has 103 tests, but the contract
with Claude Code is undocumented and could change. Claiming stability (v1.0)
before the upstream dependency stabilizes would set false expectations.
v1.0.0 is reserved for when: (a) the CC hook API is documented or stable
enough to depend on, and (b) the integration test suite runs in CI.

### D3: CC Version Granularity — Tested Floor

**Decision**: State compatibility as `>= 2.1.50` (tested floor) with no
upper bound. Do not pin to exact versions or claim minor-range compatibility.

**Alternatives considered**:

| Granularity | Example | Pros | Cons | Verdict |
| --- | --- | --- | --- | --- |
| **Floor (chosen)** | `>= 2.1.50` | Honest, simple | No upper bound | **Yes** |
| Exact version | `2.1.50` | Precise | Needs update on every CC patch | No |
| Minor range | `2.1.x` | npm-style | Assumes CC semver | No |
| Version range | `2.1.50 - 2.3.0` | Bounded | Must test upper bound | No |

**Rationale**: Claude Code does not follow semantic versioning in the
traditional sense for its hook contract. A patch release (2.1.51) could
theoretically change hook stdin format. Claiming `2.1.x` compatibility would
promise something CC itself does not guarantee. The floor approach is honest:
"we tested against 2.1.50 and it works; newer versions probably work too but
we haven't verified." This is how most projects handle undocumented upstream
dependencies.

### D4: First Compatibility Baseline — Claude Code 2.1.50

**Decision**: The first CC compatibility baseline is **2.1.50**, detected
from the development environment on 2026-02-21.

```text
$ claude --version
2.1.50 (Claude Code)
```

This version is the floor for Plankton v0.1.0. All 103 integration tests
(when fully operational) will be run against this version. The README and
config.json will reference this version.

### D5: Compatibility Info Location — README + config.json + Release Notes

**Decision**: The CC compatibility baseline is recorded in three locations,
each serving a different audience.

| Location | Audience | Format | Purpose |
| --- | --- | --- | --- |
| README badge | Repo browsers | Badge + text | At-a-glance |
| `config.json` field | Hooks | `"cc_tested_version"` | Future warning |
| Release notes | Update trackers | Prose | Per-release info |

**Why not a dedicated COMPATIBILITY.md?** Premature for v0.x with a single
row (one Plankton version, one CC baseline). The README section covers it.
A compatibility matrix document is warranted when there are multiple
Plankton versions in the wild with different CC baselines.

**Why config.json?** The hooks already read `config.json` at startup via
`jaq`. Adding `cc_tested_version` pre-positions the field for a future
runtime advisory warning (see D7) without any script changes when that
feature is implemented.

### D6: Guarantee Language — "Tested & Verified"

**Decision**: Use factual, verifiable language. No promises beyond test
results.

**Chosen language**: "Tested with Claude Code >= 2.1.50 — integration tests
pass against this version."

**Alternatives considered**:

| Language | Risk | Verdict |
| --- | --- | --- |
| **"Tested & verified" (chosen)** | None — factual claim | **Yes** |
| "Compatible with" | Implies promise beyond testing | No |
| "Guaranteed to work" | Legal/expectation liability | No |
| "Officially supports" | Implies support commitment | No |
| "Best-effort compatible" | Vague, unverifiable | No |

**Rationale**: Open-source projects should make verifiable statements.
"Integration tests pass against CC 2.1.50" is a fact. "Compatible
with CC 2.x" is a promise. [2]

[2] v0.1.0 baseline: 94/103 pass, 2 fail (test-spec issues, not hook
failures), 7 skip (absent tools). See
`.claude/tests/hooks/results/RESULTS.md`. The test harness does not yet
capture CC version per D11 — this run predates D11's implementation.

When a user reports breakage on CC 2.3.0, the
factual framing makes the situation clear: "2.3.0 is above our tested
baseline; this is a CC-side change." It also avoids any implication that the
project commits to supporting specific CC versions — the dependency runs in
only one direction.

### D7: Runtime Version Warning — Deferred (Documentation Only for Now)

**Decision**: Start with documentation-only compatibility signaling. No
runtime version check in hooks for v0.1.0. The `config.json` field is
pre-positioned to enable a future runtime warning without script changes.

**Future runtime warning design** (not implemented now):

```text
[hook:advisory] Claude Code 2.3.0 > tested baseline 2.1.50 — see compatibility notes
```

**Implementation notes for future**:

- Check CC version on first PostToolUse invocation per session only (not
  every edit)
- Cache the result in a session-scoped temp file
  (`/tmp/.plankton_cc_version_${PPID}`)
- Compare `claude --version` output against `cc_tested_version` from
  config.json
- Emit `[hook:advisory]` to stderr (non-blocking, exit 0)

**Why defer?**

1. The pre-release status (v0.x) already signals instability
2. The README caution box already warns about CLI update breakage
3. Runtime version detection adds latency to every session start
4. The advisory would fire constantly for users on newer CC versions,
   creating noise without actionable information
5. Better to implement after observing actual CC-breaking-change patterns

**Why not a hard block?** Hard-blocking on untested CC versions would lock
users out of using Plankton with any CC update until the maintainer runs
tests and bumps the baseline. This is hostile for a pre-release tool whose
hooks probably work fine across most CC updates.

### D8: GitHub Releases — Manual via gh CLI

**Decision**: Create GitHub Releases manually using `gh release create`
with auto-generated notes. No GitHub Actions automation for v0.x.

**Release command**:

```bash
git tag -a v0.1.0 -m "Plankton v0.1.0 — initial release, tested with CC 2.1.50"
git push origin v0.1.0
gh release create v0.1.0 --generate-notes --title "v0.1.0"
```

**Each release note must include**: The Claude Code version the release was
tested against, stated in the first paragraph of the release body.

**Alternatives considered**:

| Method | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **Manual gh CLI (chosen)** | Simple, no CI | Manual step | **Yes** |
| GitHub Action on tag push | Automated | Premature for v0.x frequency | Later |
| make release script | Reproducible | Another thing to maintain | Later |

**Rationale**: Release frequency for v0.x will be low (manual test runs,
manual baseline updates). Automating a process that runs a few times is
premature. `gh release create` is a single command. Automation is justified
when approaching v1.0 or when release cadence exceeds monthly.

### D9: Changelog — GitHub Release Notes Only

**Decision**: Use GitHub's auto-generated release notes from merged PRs
and commit history. No `CHANGELOG.md` file for v0.x.

**Alternatives considered**:

| Approach | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **GitHub Release notes (chosen)** | Zero maintenance | Not in git | **Yes** |
| CHANGELOG.md in repo | Versioned, always available | Manual upkeep | Later |
| Both | Complete coverage | Double maintenance | Later |

**Rationale**: CHANGELOG.md is maintenance overhead better suited for
stable projects (post-1.0) where users pin specific versions and need to
review changes between releases. For v0.x, GitHub's auto-generated notes
are sufficient. The `--generate-notes` flag on `gh release create` pulls
from PR titles and commit messages, which is adequate for the current
commit discipline. CHANGELOG.md can be introduced when approaching v1.0.

### D10: CC Update Workflow — Reactive for v0.x

**Decision**: When Claude Code updates, the maintainer uses the hooks
normally and notices breakage through daily use. No proactive testing of
every CC release.

**Workflow**:

```text
CC update drops (e.g., 2.2.0)
        |
        v
Maintainer updates CC, uses hooks normally
        |
        +-- No breakage observed --> Do nothing (baseline stays)
        |
        +-- Breakage observed:
                |
                v
            Fix hooks
                |
                v
            Run integration test suite against new CC version
                |
                v
            Update cc_tested_version in config.json
                |
                v
            Update README badge
                |
                v
            Bump Plankton version (patch or minor)
                |
                v
            Create GitHub Release with new CC baseline
```

**Alternatives considered**:

| Workflow | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **Reactive (chosen)** | Zero overhead | Late breakage discovery | **Yes** |
| Proactive per-update | Early catch | Needs CI, costly | Later |
| Periodic (weekly/monthly) | Batched effort | May miss breakage | No |

**Rationale**: The maintainer uses Plankton daily in active development.
Breakage from CC updates will be noticed immediately through normal use.
Proactive testing of every CC release requires CI infrastructure that does
not yet exist (the 103-test suite is not CI-ready). Shifting to proactive
testing is planned for when CI is established, likely as a prerequisite for
v1.0.

### D11: Test Harness Version Capture — Auto-Capture with Manual Promotion

**Decision**: The integration test suite should auto-capture
`claude --version` output and embed it in test results. The maintainer
manually reviews results and promotes the captured version to the official
`cc_tested_version` claim.

**Auto-capture behavior**:

```bash
# At start of test run, capture CC version
CC_VERSION=$(claude --version 2>&1 | head -1)
# Embed in RESULTS.md header
echo "Claude Code version: ${CC_VERSION}" >> RESULTS.md
```

**Promotion workflow**:

```text
Test suite runs, captures CC version in RESULTS.md
        |
        v
Maintainer reviews: all 103 tests pass?
        |
        +-- YES --> Update config.json cc_tested_version
        |           Update README badge
        |           Commit + tag + release
        |
        +-- NO  --> Fix failures first, re-run, then promote
```

**Rationale**: Auto-capture prevents version transcription errors (the test
suite records exactly which CC version it ran against). Manual promotion
prevents the tested baseline from advancing when tests are failing or when
the maintainer has not reviewed the results. This separation is important
because the integration tests may have stochastic failures (Claude subprocess
behavior is non-deterministic) that require human judgment to distinguish
from genuine CC breakage.

### D12: Known Limitations Documentation

**Decision**: Merge CC version compatibility guidance into the existing
README caution box rather than adding a separate note. The existing
caution box ("Research project under active development. APIs change
without notice, hooks may break on CLI updates") already covers general
instability but lacks an actionable diagnostic step.

**Merged caution box content**:

> Research project under active development. Hooks are tested against
> Claude Code >= 2.1.50 (see badge). Newer CC versions usually work
> but are not guaranteed. If you encounter breakage, file an issue
> including the output of `claude --version`.

**Rationale**: Two overlapping warnings (the existing caution box plus
a separate Known Limitations note) create visual noise. Merging them
produces a single, stronger warning that covers both general instability
and the specific CC version check. The actionable step (include
`claude --version` in bug reports) trains users to provide triage-ready
information. The existing bug report template already includes a
`Claude Code version` field (line 25 of `.github/ISSUE_TEMPLATE/
bug_report.md`), so the guidance reinforces established process.

### D13: Recommend Disabling CC Auto-Updates

**Decision**: The README should recommend that users disable Claude Code
auto-updates when using Plankton. The `stable` release channel is offered
as a softer alternative for users who want updates with a buffer.

**Context**: Claude Code's native installation (the recommended method)
includes a built-in auto-updater that downloads and installs updates in
the background. Updates take effect on next launch. Homebrew and WinGet
installations do not auto-update.

**Recommended disable method**:

```bash
export DISABLE_AUTOUPDATER=1
```

Set in shell profile or in `~/.claude/settings.json` under `"env"`.
Confirmed canonical by Anthropic staff in
[CC #9327](https://github.com/anthropics/claude-code/issues/9327).

The older `claude config set -g autoUpdates disabled` is **deprecated**
as of September 2025 per
[CC #2898](https://github.com/anthropics/claude-code/issues/2898) and
had known persistence issues.

**Softer alternative**: The `stable` channel installs versions ~1 week
behind `latest`, skipping releases with major regressions:

```bash
curl -fsSL https://claude.ai/install.sh | bash -s stable
```

**Placement**: Brief mention in the caution box (risk awareness), full
instructions in Quick Start prerequisites (actionable setup step).

**Alternatives considered**:

| Approach | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **Disable (chosen)** | User controls timing | May miss CC updates | **Yes** |
| `stable` channel | Buffered updates | Auto-update still runs | Softer option |
| No recommendation | Less friction for new users | Silent breakage risk | No |
| Hard requirement | Strongest protection | Hostile, prescriptive | No (D7) |

**Rationale**: Plankton depends on 13+ undocumented CC behaviors (see
"Scope of the Undocumented Contract"). A silent auto-update that changes
any of these could break hooks without warning. Config protection hooks
are safety-critical — if they break silently, the agent can modify linter
configs unblocked. Users should control when CC updates happen so they
can verify hooks still work after updating. The `stable` channel reduces
risk without requiring manual management, making it a reasonable middle
ground for users who prefer automatic updates.

## Implementation Plan

Ordered sequence of changes to implement the decisions above:

### Step 0: Change Repository Type (done)

The repo was a GitHub template, meaning derived repos get a snapshot
that never receives tags, releases, or updates. This is incompatible
with the versioning system (D1, D5, D8). Changed to a regular repo
via `gh api -X PATCH repos/alexfazio/plankton -f is_template=false`
on 2026-02-21. The README Quick Start must change from "Use this
template" to clone instructions (Step 2).

### Step 1: Add cc_tested_version to config.json (done)

Added `"cc_tested_version": "2.1.50"` as a top-level field in
`.claude/hooks/config.json`. Documentation field only — no hook script
reads it yet. The `$schema` validation does not reject unknown keys.

### Step 2: Update README (done)

Five changes to `README.md`:

1. **Badge** at the top (after the mascot image, before the tagline).
   Use a dynamic shields.io badge that reads `cc_tested_version` from
   `config.json` on the default branch so the badge auto-updates when
   the config file changes (single source of truth):

   ```markdown
   ![Claude Code compatibility](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Falexfazio%2Fplankton%2Fmain%2F.claude%2Fhooks%2Fconfig.json&query=%24.cc_tested_version&prefix=%3E%3D%20&label=Claude%20Code&color=blue)
   ```

2. **Auto-update recommendation** (D13) — added as Quick Start step 1
   (before "Clone the repository") with two options: `DISABLE_AUTOUPDATER=1`
   env var (full disable) or `stable` channel (softer alternative).

3. **Merge caution box** (D12) — caution box updated with CC version
   check, auto-update warning, and issue-filing guidance.

4. **Prerequisites note** — CC version check (`claude --version`) and
   tested baseline included in the new Quick Start step 1.

5. **Remove the TODO item** ("need a strategy for surviving Claude Code
   CLI updates without breaking") since this ADR addresses it.
   Done — the TODO list was rewritten during the README publication
   rewrite (commit 668be7f).

### Step 3: Commit Versioning Infrastructure

```bash
git add .claude/hooks/config.json README.md docs/specs/adr-versioning-cc-compatibility.md
git commit -m "Add versioning and CC compatibility tracking (ADR)"
```

### Step 4: Create Annotated Tag

```bash
git tag -a v0.1.0 -m "Plankton v0.1.0 — initial release, tested with Claude Code >= 2.1.50"
```

### Step 5: Push and Create GitHub Release

```bash
git push origin main --tags
gh release create v0.1.0 --generate-notes --title "v0.1.0"
```

Manually edit the release notes to include in the first paragraph:

> Tested with Claude Code >= 2.1.50.

### Step 6: Update Test Harness (Separate PR)

Modify the integration test orchestration to auto-capture `claude --version`
at the start of each test run and embed it in RESULTS.md.

## Future Work

These items are explicitly deferred and tracked here for when they become
relevant:

| Item | Trigger | Estimated Effort |
| --- | --- | --- |
| `[hook:advisory]` CC mismatch | Breaking-change patterns | 1-2h (D7) |
| CI integration tests vs CC | Test suite CI-ready | 1-2 days |
| GH Action: releases on tag push | Frequency > monthly | 1-2 hours |
| CHANGELOG.md | Approaching v1.0 | Ongoing |
| COMPATIBILITY.md matrix | Multiple Plankton versions in the wild | 1 hour |
| Proactive CC update testing workflow | When CI established | Part of CI work |
| Schema migration (approve/block -> allow/deny) | CC deprecation enforced | See [schema ADR](adr-hook-schema-convention.md) |

## References

- [Claude Code Hooks Reference (current canonical URL)](https://code.claude.com/docs/en/hooks)
- [Claude Code Setup Documentation (auto-updates section)](https://code.claude.com/docs/en/setup)
- [CC #114 — Allow disabling automatic updates](https://github.com/anthropics/claude-code/issues/114)
- [CC #12564 — Documentation inconsistency for auto-update disable setting](https://github.com/anthropics/claude-code/issues/12564)
- [CC #9327 — DISABLE_AUTOUPDATER confirmed canonical by Anthropic staff](https://github.com/anthropics/claude-code/issues/9327)
- [CC #2898 — autoUpdates config deprecated by Anthropic staff (Sept 2025)](https://github.com/anthropics/claude-code/issues/2898)
- [Semantic Versioning 2.0.0 Specification](https://semver.org/)
- [ADR: Hook JSON Schema Convention](adr-hook-schema-convention.md)
- [ADR: Hook Integration Testing](adr-hook-integration-testing.md)
- README.md:161: "strategy for surviving CC updates"
