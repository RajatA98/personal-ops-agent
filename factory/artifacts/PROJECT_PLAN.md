# Project Plan — Personal Ops Agent

**Status**: Complete
**Last Updated**: 2026-07-10

Build order is iPhone-first: get the core loop fully working and testable on iOS before extending to Mac, per the concentration risk flagged in `LOCKED_DECISIONS.md`. Each phase below is scoped to be a genuinely independent, testable unit — no phase depends on a later phase's output, and acceptance criteria are self-contained (no "see the PRD" references) so this plan can be handed directly to another tool for ticket generation without guessing at missing details.

This plan was reviewed by an independent AI council pass (codex) before finalizing; two real sequencing bugs it caught (a Phase 3 calendar-write dependency on the not-yet-built Proposal system, and a Phase 4 test referencing the not-yet-built LLM layer) are fixed below, three overly broad phases were split, and every "matches the PRD's criteria" reference was replaced with concrete, fixture-based acceptance criteria. Full review at `.claude/council-cache/council-1783663721.md`.

## Phase 0 — App Scaffold, Tooling & Engineering Contracts

**Objective**: Establish the foundational structure every later phase builds on, before any feature work starts.

**Deliverables**:
- Xcode project/workspace structure, bundle IDs, iOS/macOS deployment targets, signing set up for free-Apple-ID sideloading.
- Module boundaries: `Data`, `Integrations`, `Goals`, `Proposals`, `Reasoning`, `Voice`, `UI`.
- Test targets: unit tests, UI tests, integration-test fixtures, mock services.
- Error model: typed app errors, user-visible degraded states, retry policy, source-freshness conventions (used from Phase 2 onward).
- Logging/observability: local logs with privacy redaction, model-call audit schema (used from Phase 5 onward).
- Configuration and secrets handling: Google OAuth client config, Gemini/ElevenLabs key storage — no secrets logged, ever.
- Fixture strategy: fake Google Calendar/Gmail API, fake HealthKit data, fake reasoning provider, fake clock — every later phase's tests depend on these existing.
- CI/local validation: `xcodebuild test` runs clean on an empty scaffold.

**Acceptance criteria**:
- A new contributor (or coding tool) can build and run the app shell from a clean checkout using only this phase's documentation.
- `xcodebuild test` passes on the empty scaffold with the fixture services wired in but unused.
- No phase from here on needs to invent project structure, error-handling conventions, or test scaffolding — those are already fixed.

**Risk notes**: skipping this phase is what turns "milestone narrative" into an unbuildable plan — every later phase's acceptance criteria assume these contracts already exist.

## Phase 1 — Foundation: Local Data Model & Memory System

**Objective**: Stand up the SwiftData models and the versioned memory system, with no external integrations yet, designed to be CloudKit-compatible from day one even though sync isn't enabled until Phase 7B.

**Deliverables**:
- SwiftData models for all typed entities: `DailyLog`, `Commitment`, `Goal`, `GoalTask`, `GoalProgress`, `Decision`, `Preference`, `OpenLoop`, `Pattern`, `Proposal`.
- CloudKit-compatible schema from the start: stable app-level IDs separate from SwiftData object identity, optional/default values and relationship shapes that satisfy CloudKit's constraints, an explicit migration/versioning strategy.
- Memory lifecycle: append-only audit layer, corrections create superseding revisions (not overwrites), queries resolve to the active non-expired revision, conflicting-memory uncertainty is surfaced rather than silently resolved.
- Basic SwiftUI app shell with navigation, using Phase 0's fixtures for seed/test data only.

**Acceptance criteria**:
- Unit test: correcting a memory entity creates revision `n+1`, keeps revision `n` marked superseded (not deleted), and a default query returns only `n+1`.
- Unit test: an expired entity is excluded from the default query and present in the history query.
- Unit test: two active conflicting memories for the same fact return an explicit uncertainty/conflict result, not an arbitrary winner.
- A small test target proves the model container initializes cleanly with the intended (CloudKit-compatible) schema.
- No calendar, Gmail, HealthKit, or LLM dependency required for this phase to be fully testable.

**Risk notes**: this is the foundation everything else builds on — get the revision/versioning semantics and CloudKit-compatible schema right here, since retrofitting either later touches every other phase, including the Phase 7B sync work.

## Phase 2 — Google Calendar & Gmail Integration

**Objective**: Real, working OAuth and API access to Google Calendar and Gmail.

**Deliverables**:
- Google Cloud project/OAuth client (user-owned, Testing publishing status) wired to `ASWebAuthenticationSession`.
- Tokens stored in iOS Keychain; one-time consent flow; silent refresh.
- Calendar: read from the user's real calendar(s); create/update/delete only on a dedicated agent-owned calendar, using idempotent (caller-provided) event IDs.
- Gmail: read-only integration (`gmail.readonly`), storing message ID, thread ID, received date, and scan timestamp — not unnecessary raw body content.
- Graceful degradation using Phase 0's error model: integration failures (revoked token, network down) surface an Ops Inbox item or settings alert rather than crashing or silently omitting data.

**Acceptance criteria**:
- Real calendar events are visible in-app.
- Token refresh is tested against an expired access token.
- A revoked refresh token produces a visible reconnect state, not a crash or silent failure.
- Calendar write retry reuses the same caller-provided event ID and results in exactly one event (idempotency verified under simulated retry).
- Gmail sync stores message ID, thread ID, received date, and scan timestamp per message.

**Risk notes**: OAuth/token handling is security-sensitive — test adversarially (expired token, revoked token, malformed response) before moving on, not just the happy path.

## Phase 3A — Goal Engine & Playbooks

**Objective**: The goal data model and reusable playbook system, tested against local/seed data — no calendar writes yet.

**Deliverables**:
- Generalized goal schema (`Goal`, `GoalTask`) with playbooks for Training and Job Search: intake questions, milestone schema, task-generation rules, progress signals, review cadence, slip-detection rules, schedule-block templates, completion criteria.
- Each `GoalTask` carries flexibility (`fixed`/`movable`/`optional`), priority, earliest/latest acceptable time, expected duration, and conflict policy (`block`/`warn`/`allow`) — consumed later by Phase 4C's conflict detection.
- Goal creation/planning flow that produces a schedule **proposal preview** — not an executed calendar write. Calendar writes are explicitly out of scope for this phase; they're gated behind the Proposal system built in Phase 4A.

**Acceptance criteria**:
- Creating a Training goal and a Job Search goal from their playbooks produces genuinely distinct plans from a shared schema (not superficially similar hardcoded output).
- Slip detection correctly flags a `GoalTask` as slipped given fixture data showing no completion evidence.
- A generated schedule preview is inspectable but does not write to any calendar — verified by asserting zero calendar API calls occur during this phase's tests.

**Risk notes**: keep the playbook abstraction genuinely reusable — Training and Job Search should share real mechanics, not just a common wrapper around hardcoded logic (per the PRD's explicit red flag on this).

## Phase 3B — Daily Loop UI: Briefing, Capture, Weekly Review

**Objective**: The user-facing daily rhythm, built on Phase 1 (memory), Phase 2 (calendar/Gmail read access), and Phase 3A (goals) — all read-only against those systems, no new write paths.

**Deliverables**:
- Morning Briefing: deterministic assembly of today's real + agent-owned calendar events, active goal commitments due today, yesterday's captured reality, slipping items, and source-freshness display (calendar/Gmail/HealthKit last-synced times).
- Evening Capture: text/tap flow (voice comes in Phase 6) that updates `DailyLog`, `GoalProgress`, and `OpenLoop`.
- Weekly Review: rollup of completed/slipped/next-week tasks per active goal.
- Home/Lock Screen widget (WidgetKit) showing the briefing headline: today's #1 priority and slip count — the daily value should be glanceable without opening the app.
- One-tap complete/skip on today's `GoalTask`s, from the briefing view and the widget — logging reality must be cheaper than ignoring it, and every tap here shrinks what Evening Capture has to ask about.

**Acceptance criteria**:
- Morning Briefing generated from fixture data shows real calendar events, agent-owned events, due goal tasks, slipped items, and source freshness, each clearly attributed.
- Briefing generation succeeds (with sources visibly marked absent) when Gmail/HealthKit permissions are withheld in the fixture — never silently implies completeness it doesn't have.
- Evening Capture updates `DailyLog`, `GoalProgress`, and `OpenLoop` correctly from a scripted text/tap interaction.
- Weekly Review correctly categorizes a fixture set of tasks into completed/slipped/next-week per goal.
- Widget renders the fixture briefing headline; tapping complete/skip on a fixture `GoalTask` updates `GoalProgress` and is reflected in the next briefing assembly.

**Risk notes**: this is the highest-value phase — it's the actual product experience. Keep data assembly deterministic (Swift-triggered), not LLM-driven — the LLM only adds narrative polish starting in Phase 5.

## Phase 3C — HealthKit Pacing

**Objective**: Read-only HealthKit integration feeding pacing suggestions into goal plans.

**Deliverables**:
- HealthKit read-only permission flow for sleep/recovery-adjacent metrics.
- Pacing suggestions within goal plans (from Phase 3A) visibly labeled as HealthKit-influenced.
- A user-facing toggle to disable HealthKit influence without disabling goals themselves.

**Acceptance criteria**:
- A pacing suggestion generated from fixture HealthKit data is visibly labeled as influenced by that data.
- Denying HealthKit permission leaves goal planning and the daily loop fully functional, HealthKit-influenced suggestions simply absent.
- Disabling the toggle removes HealthKit influence without affecting goal data itself.

**Risk notes**: keep this additive and isolated — nothing else in the plan should hard-depend on HealthKit being present.

## Phase 4A — Proposal System & Ops Inbox

**Objective**: The full "propose, don't auto-act" execution layer — this is what Phase 3A's schedule previews plug into for real calendar writes.

**Deliverables**:
- Typed Proposal state machine (`remember_fact`, `create_agent_calendar_event`, `update_agent_calendar_event`, `modify_goal_plan`, `mark_goal_progress`, `snooze_open_loop`, `dismiss_signal`), each with its own execution handler and confirmation copy.
- Ops Inbox UI: approve / dismiss / schedule / remember / snooze / mark-as-wrong.
- Phase 3A's goal-plan schedule previews now route through this system — approval creates real agent-owned calendar events via Phase 2.
- Weekly Review → next-week draft: the Phase 3B Weekly Review ends by generating next week's proposed schedule blocks as a *batch* of `create_agent_calendar_event` Proposals, so one Sunday approval session plans the week. Batch approval/dismissal supported in the Ops Inbox UI.

**Acceptance criteria**:
- Each Proposal type has a test proving approval invokes only its own handler — no inferred follow-up actions occur.
- Dismissed, snoozed, and expired proposals never execute.
- Approving a `create_agent_calendar_event` Proposal from a Phase 3A goal-plan preview results in exactly one calendar event via Phase 2's idempotent write path.
- A fixture Weekly Review produces a batch of next-week Proposals; batch-approving creates exactly the approved events, and dismissing individual items from the batch excludes only those.

**Risk notes**: this is the safety-critical core of the whole app — test the negative cases (dismissed/expired/rejected never execute) as thoroughly as the happy path.

## Phase 4B — Gmail-Derived Signals

**Objective**: Turn Gmail content (from Phase 2) into Proposals (via Phase 4A).

**Deliverables**:
- Gmail-derived Proposals with dedupe by thread/message ID.
- Downranking/suppression of similar future extraction after a user "mark as wrong."

**Acceptance criteria**:
- A duplicate scan of the same Gmail thread does not create a second pending Proposal.
- Marking a Gmail-derived Proposal as wrong measurably suppresses similar future extraction from that source pattern in a follow-up fixture scan.

**Risk notes**: false positives here directly cost user trust in the Ops Inbox — bias toward under-proposing rather than over-proposing when extraction confidence is low.

## Phase 4C — Conflict Detection & Shortcuts Intake

**Objective**: Cross-goal conflict detection (using Phase 3A's `GoalTask` metadata) and iMessage ingestion via Shortcuts (producing Proposals via Phase 4A).

**Deliverables**:
- Cross-goal conflict detection using each `GoalTask`'s flexibility/priority/conflict-policy metadata.
- iMessage ingestion via a user-configured Shortcuts automation handing text to an app-exposed URL scheme/App Intent, tagged with explicit untrusted/best-effort source metadata.

**Acceptance criteria**:
- Conflict detection has fixture coverage for fixed/fixed, fixed/movable, and movable/optional task pairs, correctly applying `block`/`warn`/`allow` per their configured policy.
- A Shortcut-forwarded text produces a classified Proposal, never a silent write.
- A malformed or delayed Shortcut payload is dropped (or surfaced as an error) rather than guessed into memory.

**Risk notes**: iMessage coverage is inherently best-effort (see Locked Decisions) — don't let this phase's tests imply guarantees the underlying mechanism can't actually provide.

## Phase 5 — LLM Reasoning Layer & Tool-Calling

**Objective**: Wire Gemini Flash into the app as the reasoning layer, behind the `ReasoningProvider` abstraction, for narrative generation and free-form Q&A — and this is where the LLM-specific safety tests belong (not Phase 4, which has no LLM yet).

**Deliverables**:
- `ReasoningProvider` abstraction with a Gemini Flash implementation.
- LLM-generated narrative for Morning Briefing/Weekly Review, grounded in Phase 3B's deterministically-assembled context (the LLM never fetches data itself for these flows).
- Agentic tool-calling for free-form Q&A over memory, using the read/propose tool split locked in Decide: read tools (`search_calendar`, `search_gmail`, memory search) execute immediately; any tool that would change state only ever creates a Proposal via Phase 4A.
- Model-call logging (timestamp, purpose, input categories, provider, whether raw external content was included), per Phase 0's audit schema.

**Acceptance criteria**:
- Fixture test: given deterministic briefing context, the model's narrative output references only facts present in that context (no fabrication).
- Fixture test: given no relevant memory, a free-form Q&A query returns an explicit "I don't know," not a fabricated answer.
- Tool registry test proves no tool exposed to the LLM can directly mutate the real calendar or send anything — every state-changing tool only creates a Proposal.
- Model-call logging test verifies required metadata is persisted and that tokens/headers are never logged.

**Risk notes**: confirm the `ReasoningProvider` abstraction is clean enough that swapping providers (e.g., to Claude) is a config change, not a rewrite, before calling this phase done — that was the entire point of the abstraction.

## Phase 6 — Voice Interface

**Objective**: Real conversational voice, layered on top of the now-working text/data loop. Two internal milestones: plumbing first, then conversational behavior.

**Deliverables**:
- *Milestone 1 — Plumbing*: on-device STT (Apple Speech framework) for capture; ElevenLabs TTS for playback with a swappable-provider fallback to `AVSpeechSynthesizer`.
- *Milestone 2 — Conversational behavior*: full turn-taking conversation UI, user-interruptible playback, low-confidence-transcription confirmation before creating a Proposal or memory entry, voice-first Evening Capture.
- Transcripts not stored as memory by default — only on confirmed/approved updates.

**Acceptance criteria**:
- Playback can be interrupted within a defined latency target.
- A low-confidence transcript requires explicit user confirmation before it creates a Proposal or memory entry.
- A transcript is not persisted unless confirmed/approved.
- Simulated ElevenLabs failure falls back to `AVSpeechSynthesizer` without breaking the conversation.
- Voice-driven Evening Capture completes in a single interaction for the common case.

**Risk notes**: "feels good to talk to" is a real risk, not an acceptance criterion — budget time for iteration on real daily use beyond what these tests can verify.

## Phase 7A — CloudKit Sync Hardening

**Objective**: Enable and harden CloudKit sync on Phase 1's already-CloudKit-compatible schema, isolated from the Mac UI work in 7B.

**Deliverables**:
- CloudKit sync enabled on the existing SwiftData schema.
- Conflict-resolution behavior, migration handling, dedupe, and deletion/tombstone behavior defined and tested.
- A multi-device test matrix (can be run with two iOS simulators/devices before the Mac target exists).

**Acceptance criteria**:
- Sync convergence within a defined target window under normal connectivity.
- Test matrix passes: create/approve on device A observed on device B; resolve on B observed on A; offline edit then reconnect; duplicate prevention; deletion/tombstone behavior.
- A CloudKit migration test runs successfully against existing local (pre-sync) data.

**Risk notes**: this was explicitly flagged in Presearch as SwiftData's least mature feature area — budget real testing time here, don't assume first-pass correctness. Must not start until Phases 0–6 are stable (concentration-risk note from Locked Decisions).

## Phase 7B — macOS App Target

**Objective**: The Mac UI itself, consuming the sync foundation from 7A.

**Deliverables**:
- macOS app target sharing the SwiftUI codebase/business logic from Phases 0–6.
- Platform-specific handling: Mac consumes HealthKit-derived pacing insights as synced data (Phase 3C) rather than reading HealthKit natively; iMessage/Shortcuts behavior on Mac confirmed and documented (may differ from iOS); voice (STT/TTS) verified on Mac's mic/speakers.
- Google OAuth token-sharing approach between devices decided and implemented (iCloud Keychain sync vs. independent per-device authorization).

**Acceptance criteria**:
- The core loop (Briefing, Goals, Ops Inbox, Memory Q&A, Voice) is usable end-to-end on Mac.
- A Proposal approved on iPhone appears resolved on Mac within 7A's sync convergence target, and vice versa.
- No data loss or duplication observed across a full sync cycle exercising both devices concurrently.

**Risk notes**: don't start this until 7A's sync behavior is verified solid — building Mac UI against flaky sync just relocates the bugs, not fixes them.

## Handoff Note

This plan is structured for the user's intended workflow: refine each phase into concrete tickets (with a different model/tool), then implement (with another), with a third orchestrating across phases. Phase boundaries are drawn so each one can be ticketed, implemented, and verified independently — a downstream phase should never need to reopen a completed upstream phase's internals, only consume its outputs. All acceptance criteria above are self-contained (no external "see the PRD" references) specifically so a ticketing pass doesn't have to chase another artifact to know what "done" means.
