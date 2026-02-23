# PostToolUse Hook Output Regression: Deep Research Report

External research findings on the Claude Code PostToolUse hook output
regression bug, gathered via Exa deep research (exa-research-pro model)
on 2026-02-21. Cross-references 48 GitHub issues, the official changelog,
and community reports.

**Research date**: 2026-02-21
**Research model**: exa-research-pro
**Cost**: $0.82 (68 pages crawled, 23 searches)
**Parent spec**: `posttoolusewrite-hook-stderr-silent-drop.md`

## Key Finding: Regression Window

**Last working version**: v2.1.31
**First broken version**: v2.1.41
**Regression window**: v2.1.31 to v2.1.41

This is more precise than the first-party JSONL bisection (which covered
v2.1.9-v2.1.50 and found zero working versions), because the external
evidence from GitHub issues provides positive proof of the feature working
in v2.1.31 that JSONL data could not capture.

## Regression Timeline (Consolidated)

| Version | PostToolUse Output Status | Evidence |
| ------- | ------------------------ | -------- |
| v2.0.35 | `exit 2 + stderr` **worked** | [#11224][i11224]: Empirically documents that exit 2 + stderr was the one working PostToolUse output path. Earliest confirmed evidence of the feature functioning. |
| v2.1.31 | `decision:block` JSON **reached agent** as `<system-reminder>` blocks (duplicated) | [#23381][i23381]: Reports duplication bug where PostToolUse `decision:block` output appeared twice in Claude's context. Proves the JSON propagation path existed and delivered content to the model. |
| v2.1.41 | **UI-only fix** — stderr shown in terminal, NOT in API context | [CHANGELOG][changelog]: "Fixed hook blocking errors: exit code 2 now correctly shows stderr output to the user." The phrase "to the user" means terminal display only. API-level propagation was not restored. |
| v2.1.50 | **All 5 output channels silently dropped** | [#18427][i18427], [#24788][i24788], [#27314][i27314]: Multiple independent confirmations that no PostToolUse output channel reaches the agent. Five-channel test matrix (stderr/stdout, exit 0/1/2, plain text/JSON) all silently dropped. |

## Question 1: Last Version with Working PostToolUse Output

### Answer: v2.1.31

Evidence: GitHub issue [#23381][i23381] reports that in v2.1.31,
PostToolUse hooks with `exit 2` injected `<system-reminder>` blocks into
Claude's context. The issue describes a *duplication* bug (the output
appeared twice), which proves the output was reaching the model at all.
The fix for this duplication bug is the likely cause of the regression —
the output path was disabled rather than deduplicated.

Prior to v2.1.31, issue [#11224][i11224] documents that `exit 2 + stderr`
was the one working PostToolUse output path in v2.0.35. This is the
earliest confirmed evidence.

## Question 2: First Version Where It Broke

### Answer: v2.1.41

The v2.1.41 changelog entry states: "Fixed hook blocking errors: exit
code 2 now correctly shows stderr output to the user." This fix addressed
terminal UI rendering only. Issues filed after v2.1.41 ([#18427][i18427],
[#24788][i24788]) confirm that API-level propagation remained broken.

The regression therefore occurred between v2.1.31 (last confirmed working)
and v2.1.41 (first confirmed broken at the API level despite the UI fix).
The exact commit is unknown — the window spans approximately 10 minor
versions.

## Question 3: Was the v2.1.41 Fix UI-Only?

**Answer: Yes, confirmed UI-only.**

The changelog wording is "shows stderr output to the user" — this means
the terminal progress indicator (`PostToolUse:Write hook error`), not the
API `tool_result` content field. Issues [#18427][i18427] and
[#24788][i24788], filed after v2.1.41, explicitly confirm that
`additionalContext`, `systemMessage`, `modifyResult`, and plain text
stdout all fail to reach the model. The v2.1.41 fix did not restore
API-level propagation.

## Question 4: What Code Change Caused the Regression?

**Answer: No single commit identified, but probable cause narrowed.**

No pull request or commit is explicitly cited in the GitHub issues as the
direct cause. However, the evidence points to changes in the hook
execution and plugin system around v2.1.31:

- [#9208][i9208]: Duplicate PostToolUse:Edit hook calls causing API
  concurrency errors
- [#10871][i10871]: Plugin-registered hooks executed twice with different
  PIDs
- [#23381][i23381]: PostToolUse blocking error displayed twice (regression)

These issues describe duplicate hook execution bugs and their fixes. The
fixes for the duplication problem likely over-corrected by disabling the
PostToolUse output propagation path entirely, rather than deduplicating
it. This is consistent with the debug log finding in the parent spec:
hook output is parsed successfully but then discarded in the "normal
processing" path after the async check.

## Question 5: Has Anthropic Acknowledged This? Planned Fix?

**Answer: Acknowledged via multiple open issues. No published timeline.**

### Open issues confirming the bug

| Issue | Title | Status |
| ----- | ----- | ------ |
| [#18427][i18427] | PostToolUse hooks cannot inject context visible to Claude | **Open** |
| [#24788][i24788] | PostToolUse hooks with additionalContext not surfacing for MCP tool calls | **Open** |
| [#27314][i27314] | Async PostToolUse hook systemMessage not delivered | **Open** |
| [#12151][i12151] | Plugin hook output not captured or passed to agent (umbrella issue) | **Open** |

### Closed/duplicate issues

| Issue | Title | Status |
| ----- | ----- | ------ |
| [#25987][i25987] | Plugin hooks returning systemMessage: content not injected | Closed (dup of #12151) |
| [#23381][i23381] | PostToolUse hook blocking error displayed twice | Closed |
| [#13650][i13650] | SessionStart hook stdout silently dropped | Closed (fixed v2.0.76) |

No roadmap milestone or scheduled fix has been published for any of the
open issues. Issue [#12151][i12151] appears to be the umbrella tracking
issue but has no assigned milestone.

## New Issues Discovered (Not in Parent Spec)

The deep research uncovered several additional related issues not
previously referenced in the parent spec:

| Issue | Title | Relevance |
| ----- | ----- | --------- |
| [#3983][i3983] | PostToolUse hook JSON output not processed | Early report of JSON output being ignored |
| [#12151][i12151] | Plugin hook output not captured or passed to agent | **Umbrella issue** — #25987 closed as dup of this |
| [#25987][i25987] | Plugin hooks `systemMessage` not injected into model context | Closed as dup of #12151 |
| [#10871][i10871] | Plugin-registered hooks executed twice with different PIDs | May have caused the regression when fixed |
| [#9208][i9208] | Duplicate PostToolUse:Edit hook calls causing API concurrency errors | Related to hook execution deduplication |
| [#10814][i10814] | Hooks broken again in v2.0.31 (regression after v2.0.30 fix) | Earlier hook regression, similar pattern |
| [#15441][i15441] | PreToolUse and PostToolUse hooks not firing | Complete hook failure (different from output drop) |
| [#20334][i20334] | PostToolUse hook with tool-specific matcher runs for all tools | Matcher bug (separate from output drop) |
| [#22541][i22541] | PostToolUse:Edit hook incorrectly blocking continuation | Hook blocking behavior issue |
| [#8867][i8867] | Missing tool result block for tool use ID + hooks execution output as user messages | Early hook output routing issue |

## Implications for the Make-Plankton-Work Plan

### Downgrading is not viable

Even v2.1.31 (the last "working" version) only delivered PostToolUse
output as duplicated `<system-reminder>` blocks — a known bug. There is
no version where PostToolUse output was both (a) delivered to the agent
AND (b) correctly formatted without duplication. Downgrading is a dead
end.

### The PreToolUse gate workaround (Strategy 4) remains the correct approach

The research confirms:

1. PreToolUse output IS reliably delivered (no issues found with
   PreToolUse output propagation)
2. PostToolUse output has been broken since at least v2.1.41
3. No fix is scheduled
4. The bug is acknowledged but deprioritized

### The upstream bug report (Step 4) should reference #12151

Issue [#12151][i12151] is the umbrella tracking issue for hook output
propagation bugs. The upstream report should cross-reference it and
potentially comment on it rather than filing a completely new issue.

### New cross-references for Step 4

The upstream bug report should include these additional issues discovered
by this research:

- #3983, #12151, #25987, #10871, #9208

## Source Citations

### GitHub Issues

| Ref | URL |
| --- | --- |
| [#3983][i3983] | <https://github.com/anthropics/claude-code/issues/3983> |
| [#8867][i8867] | <https://github.com/anthropics/claude-code/issues/8867> |
| [#9208][i9208] | <https://github.com/anthropics/claude-code/issues/9208> |
| [#10814][i10814] | <https://github.com/anthropics/claude-code/issues/10814> |
| [#10871][i10871] | <https://github.com/anthropics/claude-code/issues/10871> |
| [#11224][i11224] | <https://github.com/anthropics/claude-code/issues/11224> |
| [#12151][i12151] | <https://github.com/anthropics/claude-code/issues/12151> |
| [#13650][i13650] | <https://github.com/anthropics/claude-code/issues/13650> |
| [#15441][i15441] | <https://github.com/anthropics/claude-code/issues/15441> |
| [#18427][i18427] | <https://github.com/anthropics/claude-code/issues/18427> |
| [#19009][i19009] | <https://github.com/anthropics/claude-code/issues/19009> |
| [#20334][i20334] | <https://github.com/anthropics/claude-code/issues/20334> |
| [#22541][i22541] | <https://github.com/anthropics/claude-code/issues/22541> |
| [#23381][i23381] | <https://github.com/anthropics/claude-code/issues/23381> |
| [#24788][i24788] | <https://github.com/anthropics/claude-code/issues/24788> |
| [#25987][i25987] | <https://github.com/anthropics/claude-code/issues/25987> |
| [#27314][i27314] | <https://github.com/anthropics/claude-code/issues/27314> |

### Other Sources

| Source | URL |
| ------ | --- |
| Claude Code CHANGELOG.md | <https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md> |
| Claude Code Hooks Reference (official) | <https://code.claude.com/docs/en/hooks> |
| Claude Code Changelog (official) | <https://code.claude.com/docs/en/changelog> |
| Claude Code Releases | <https://github.com/anthropics/claude-code/releases> |
| Reddit: Hook errors after updating | <https://www.reddit.com/r/ClaudeAI/comments/1q7lq8z/anyone_else_getting_hook_errors_after_updating> |
| Reddit: Claude Code 2.1.41 released | <https://www.reddit.com/r/ClaudeAI/comments/1r3lxpe/official_anthropic_just_released_claude_code_2141> |
| claude-flow #1172: hook-handler.cjs breaks PostToolUse | <https://github.com/ruvnet/claude-flow/issues/1172> |

<!-- Reference-style links -->
[i3983]: https://github.com/anthropics/claude-code/issues/3983
[i8867]: https://github.com/anthropics/claude-code/issues/8867
[i9208]: https://github.com/anthropics/claude-code/issues/9208
[i10814]: https://github.com/anthropics/claude-code/issues/10814
[i10871]: https://github.com/anthropics/claude-code/issues/10871
[i11224]: https://github.com/anthropics/claude-code/issues/11224
[i12151]: https://github.com/anthropics/claude-code/issues/12151
[i13650]: https://github.com/anthropics/claude-code/issues/13650
[i15441]: https://github.com/anthropics/claude-code/issues/15441
[i18427]: https://github.com/anthropics/claude-code/issues/18427
[i19009]: https://github.com/anthropics/claude-code/issues/19009
[i20334]: https://github.com/anthropics/claude-code/issues/20334
[i22541]: https://github.com/anthropics/claude-code/issues/22541
[i23381]: https://github.com/anthropics/claude-code/issues/23381
[i24788]: https://github.com/anthropics/claude-code/issues/24788
[i25987]: https://github.com/anthropics/claude-code/issues/25987
[i27314]: https://github.com/anthropics/claude-code/issues/27314
[changelog]: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
