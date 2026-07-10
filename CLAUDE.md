# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

Personal Ops Agent — a single-user, native Apple app (iOS primary, macOS companion) that acts as a daily operating layer over the user's life: morning briefing, evening capture, goal tracking (triathlon training, job search), and an LLM reasoning layer with a strict "propose, don't auto-act" safety model. Built for exactly one user (the repo owner); never multi-user, never App Store.

## Where Truth Lives

All product/architecture decisions are in `factory/artifacts/` — read these before making design choices, and treat `LOCKED_DECISIONS.md` as fixed constraints, not suggestions:

- `PROBLEM_SUMMARY.md` — what this is, why, scope decisions and their history
- `PRD.md` — requirements, acceptance criteria per flow, data boundaries/privacy classes, integration failure modes
- `PRESEARCH.md` — tech-stack discussion record and rationale
- `LOCKED_DECISIONS.md` — the locked stack (changing one means reopening Plan, not a mid-build pivot)
- `PROJECT_PLAN.md` — the 13-phase build plan (Phase 0 → 7B), each phase with self-contained acceptance criteria
- `AGENT_DESIGN.md` — agent structure (bounded native tool-calling loop for Q&A/voice only; single-call workflows elsewhere), tool registry with the read/propose split, context budgets per flow, prompt conventions, golden-fixture eval spec

Council review outputs (independent AI critiques that shaped these artifacts) are cached in `.claude/council-cache/`.

## Locked Stack (summary — see LOCKED_DECISIONS.md for rationale)

- **Swift/SwiftUI**, iOS + macOS targets sharing one codebase; sideloaded via free Apple ID (7-day resign cycle accepted), no App Store
- **No backend we run.** Fully on-device; iPhone↔Mac sync via SwiftData + CloudKit (Phase 7A, schema must be CloudKit-compatible from Phase 1)
- **SwiftData** for storage (GRDB is the documented fallback for the memory subsystem only)
- **Direct Google REST APIs** (Calendar + Gmail) via `ASWebAuthenticationSession`, tokens in Keychain. No MCP.
- **Gemini Flash** as runtime reasoning model behind a swappable `ReasoningProvider` abstraction
- **Voice**: on-device STT (Apple Speech) + ElevenLabs TTS (fallback: `AVSpeechSynthesizer`)
- **iMessage** only via user-configured Shortcuts automation; **HealthKit** read-only

## Non-Negotiable Safety Rules

These are architectural constraints, not prompt-level suggestions:

1. **The LLM never gets a tool that mutates real state.** Tools are split: read tools (execute immediately) and propose tools (write only to the local Proposal queue). Calendar writes, goal-plan changes, anything externally visible — all gated behind user approval in the Ops Inbox.
2. **Agent calendar writes go only to the dedicated agent-owned calendar**, with idempotent caller-provided event IDs. Never write to the user's real calendars.
3. **Memory is append-only at the audit layer.** Corrections create superseding revisions preserving prior value/source/timestamp — never destructive overwrites.
4. **Nothing is ever auto-sent** (email, text) on the user's behalf. No exceptions.
5. **Secrets are never logged** — no tokens, no auth headers. OAuth tokens live in Keychain only.
6. **Degrade visibly, never silently** — a briefing with a dead integration says so rather than implying completeness.

## Build & Test

Phase 0 scaffold is in place: a thin hand-authored `PersonalOpsAgent.xcodeproj` (file-system-synchronized groups — new files under `App/` are picked up without pbxproj edits) + local Swift Package `Packages/PersonalOpsKit` holding all module code (Core, Data, Integrations, Goals, Proposals, Reasoning, Voice, UI, Fixtures).

- Fast unit tests (all package logic): `cd Packages/PersonalOpsKit && swift test`
- Full app build: `xcodebuild build -project PersonalOpsAgent.xcodeproj -scheme PersonalOpsAgent -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
- Full test suite (app + UI): `xcodebuild test -project PersonalOpsAgent.xcodeproj -scheme PersonalOpsAgent -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2'`

Conventions fixed by Phase 0 (see `docs/SETUP.md`): iOS deployment target 18.0; package is Swift 6 strict-concurrency-clean; secrets go in `Secrets/Config.local` (gitignored; template at `Secrets/Config.example`) and are registered with `RedactingLogger` at startup; `AppEntity.appID` is the stable-ID convention for CloudKit compatibility; `ProposalType`/`ProposalStatus`/`TaskFlexibility`/`ConflictPolicy` shared vocabulary lives in the package — reuse it, don't redefine.

## Working Conventions

- Phases in `PROJECT_PLAN.md` are strictly ordered (0 → 1 → 2 → 3A/3B/3C → 4A/4B/4C → 5 → 6 → 7A → 7B). A downstream phase consumes upstream outputs; it never reopens upstream internals.
- Every phase's acceptance criteria are self-contained in the plan — implement against those, not a reinterpretation of the PRD.
- Deterministic flows (Briefing, Capture, Weekly Review) assemble their data in Swift; the LLM adds narrative only. Agentic tool-calling is reserved for free-form Q&A.
- The user is non-technical: explain jargon when discussing design, and never say "just" for nontrivial steps.
