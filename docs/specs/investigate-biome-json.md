# Investigation: Missing biome.json

## Context

During fact-checking of `docs/specs/benchmarks/adr-plankton-benchmark.md`, the
prerequisite check on line 665 referenced `biome.json` as a linter config that
should be present in the repo root. However, no `biome.json` file exists.

The benchmark ADR has been updated to remove `biome.json` from the check, but
the expectation that it should exist needs investigation.

## Questions to resolve

1. Was `biome.json` previously in the repo and accidentally deleted/gitignored?
2. Should Biome be configured for any JS/TS files in this project?
3. If Biome is intended, what configuration is needed?
4. If not needed, are there other references to Biome that should be cleaned up?

## Status

- [ ] Investigate git history for prior `biome.json`
- [ ] Check if any JS/TS source files exist that would need Biome
- [ ] Decide: add `biome.json` or remove all Biome references
