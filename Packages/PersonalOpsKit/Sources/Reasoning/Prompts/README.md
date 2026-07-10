# Reasoning Prompts

Per AGENT_DESIGN.md §5, system prompts are **code**: one versioned plain-text file per
flow, with a version header, reviewed/diffed/fixture-tested like any other source.

These files are bundled as a processed resource of the `Reasoning` target (see
`Package.swift`). Phase 5 adds the actual prompt files here, e.g.:

- `morning-briefing.v1.txt`
- `weekly-review.v1.txt`
- `classification.v1.txt`
- `qa-preamble.v1.txt`

Phase 0 ships only this folder + convention so Phase 5 has a home to drop into. No prompt
contains provider-specific syntax — the `ReasoningProvider` implementation owns message
formatting so the Gemini → any-provider swap stays a config change.
