# Implementation Log — Personal Ops Agent

**Status**: In Progress
**Last Updated**: 2026-07-10

Running record of what each phase actually built, by which agent, and what downstream phases need to know. Orchestrated per the standing pipeline (Fable orchestrates, Opus implements in isolated worktrees, TDD, merge on green).

## Phase 0 — App Scaffold, Tooling & Engineering Contracts ✅ (merged `004b340`)

- **Structure chosen**: SPM-hybrid — thin hand-authored `PersonalOpsAgent.xcodeproj` (file-system-synchronized groups) + local package `Packages/PersonalOpsKit` holding all logic in targets: Core, Data, Integrations, Goals, Proposals, Reasoning, Voice, UI, Fixtures. Rationale: no xcodegen/tuist installed; SPM gives fast host-side `swift test` and macOS reuse for Phase 7B (package declares `.macOS(.v15)`).
- **Delivered**: typed `AppError` + `DegradedState`, `RetryPolicy`, `SourceFreshness`, `RedactingLogger` (secret registration), `ModelCallAudit` (Codable-verified to carry no token/header fields), `Config` (reads gitignored `Secrets/Config.local`; template `Secrets/Config.example`), five fixture fakes (Google Calendar, Gmail, HealthKit, ReasoningProvider, Clock), `docs/SETUP.md`.
- **Verified**: from a fresh clone — `swift test` 33/33; `xcodebuild test` (iPhone 16 Pro, iOS 18.2) TEST SUCCEEDED. iOS deployment target 18.0; package swift-tools 6.0, strict-concurrency-clean.
- **Signing**: `CODE_SIGN_STYLE = Automatic`, no team pinned; device sideloading = select free-Apple-ID team in Xcode once.

## Phase 1 — Local Data Model & Versioned Memory System ✅ (merged from `2533ff1`)

- **Schema**: ten `@Model` entities — revisionable MemoryEntities (`DailyLog`, `Commitment`, `Goal`, `GoalProgress`, `Decision`, `Preference`, `OpenLoop`, `Pattern`, `Proposal`) plus structural child `GoalTask` (child of `Goal`; corrections to it happen via `modify_goal_plan` Proposals, not revisions).
- **Identity model**: `appID` (stable per-revision app-level ID), `factKey` (semantic identity shared across a fact's revisions/conflicting claims), `supersededByAppID` (audit back-pointer).
- **Revision mechanism**: all writes via `MemoryStore` (`insert`/`correct`/`expire`/`resolve`/`history`). `correct()` copies value fields to a new row (revision n+1), stamps the old row superseded — never mutates in place. `resolve(factKey:)` returns `.none`/`.resolved`/`.conflict` — conflicts are explicit, never an arbitrary winner. Expiry evaluated against injected `Clock`.
- **CloudKit-shaped**: no unique attributes (appID uniqueness is a write-time convention), all attributes optional-or-defaulted, all relationships optional with explicit inverses, enums stored as raw String. `DataSchemaV1: VersionedSchema` + `MemoryMigrationPlan` (baseline); `DataModule.schemaVersion = 1`. CloudKit sync itself OFF until Phase 7A (host-side compat proven; `.automatic` container needs an iCloud-entitled device build).
- **Latitude decision**: shared vocabulary (`TaskFlexibility`, `ConflictPolicy`, `ProposalType`, `ProposalStatus`, new `MemorySource`) relocated to `Core/Vocabulary.swift` — Data must store these types and can't import Goals/Proposals. Relocation, not redefinition.
- **Verified**: `swift test` 47/47 (33 + 14 new); `xcodebuild test` TEST SUCCEEDED; zero warnings; strict-concurrency-clean.
- **Gotchas for later phases**: module named `Data` collides with `Foundation.Data` (can't module-qualify `Data.X`); `Pattern` collides with a C Quickdraw type in test targets (infer, don't name in type position); generic `#Predicate` over the MemoryEntity protocol doesn't compile — store filters post-fetch; `MemoryStore` is not Sendable (construct on the ModelContext's owning actor); always set `factKey` on insert (two entities left at default `""` read as one fact).

## Phase 2 — Google Calendar & Gmail Integration 🔄 (in progress)

Dispatched with Phase 0/1 handoff notes. Live-credential caveat: real Google OAuth requires the user to create their own Google Cloud OAuth client; implementation is live-capable but verified against URLProtocol-mocked integration tests + fixtures until the user supplies `Secrets/Config.local`.
