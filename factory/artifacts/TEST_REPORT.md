# Test-QA Report — Personal Ops Agent

**Status**: Complete — Ready for user (on-device) QA
**Last Updated**: 2026-07-10
**Phase**: Project Factory Phase 8 of 9 (Test-QA). Builds on the ship-ready verdict in `REVIEW_REPORT.md`; the device/account-gated items here are the EXPECTED gaps consolidated in `IMPLEMENTATION_LOG.md`, not new defects.

---

## 1. Suite Results (run by this phase, on a clean checkout)

| Suite | Command | Result |
|---|---|---|
| Package unit tests — run 1 | `cd Packages/PersonalOpsKit && swift test` | **255 / 255 passed**, 0 failures (0.645s) |
| Package unit tests — run 2 (flakiness) | `swift test` again | **255 / 255 passed**, 0 failures (0.638s) |
| Package unit tests — after +5 edge-case tests (×3 runs) | `swift test` | **260 / 260 passed**, 0 failures (~0.63s each) |
| iOS app + UI suite | `xcodebuild test … -scheme PersonalOpsAgent -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2'` | **TEST SUCCEEDED** |
| macOS build | `xcodebuild build -scheme PersonalOpsAgentMac -destination 'platform=macOS'` | **BUILD SUCCEEDED** (ad-hoc Debug signing, no cert) |

**Flakiness verdict: NONE.** Two back-to-back `swift test` runs produced identical counts (255/255) and the same per-suite results; three further runs at the new total (260/260) were identical. Time is injected everywhere via `FakeClock`/an explicit `Calendar` (no `Date()`/`.current` in logic paths), and no test depends on ordering — so there is no clock- or order-dependent flakiness. Total wall time is sub-second, confirming the suite is pure/host-side with no network or real I/O.

**iOS `xcodebuild test` detail**: the 255→260 package tests run via `swift test`. The iOS scheme's own targets are the app-level `AppUnitTests` (the two `KeychainTokenStoreTests` are `XCTSkip`ped on the unsigned simulator by design — real-Keychain roundtrip needs a signed/device build) and `AppUITests` (a launch smoke test that passed in ~4.3s, confirming the app boots with all tabs, widget, App Intent, and voice UI). This is the intended split: logic is proven host-side by the package suite; the xcodebuild run proves the app compiles, links, embeds the widget, and launches.

---

## 2. Coverage Assessment — PRD Acceptance Criteria → Tests

Every PRD "Acceptance Criteria (per core flow)" clause is mapped below. **Legend**: ✅ Covered (host-side unit test), 🟡 Partial (core logic covered; a real-use/trigger facet is device- or subjective-gated), 🔵 Device/account-gated (expected — see the consolidated checklist in `IMPLEMENTATION_LOG.md`).

### Morning Briefing
| Criterion | Test(s) | Status |
|---|---|---|
| Real vs agent-owned events shown separately | `BriefingAssemblerTests.test_briefingShowsAttributedEventsDueTasksSlippedAndFreshness` | ✅ |
| Active goal commitments due today shown | same test (`dueTasks`) | ✅ |
| ≥1 slipped item flagged when yesterday's task lacks completion evidence | same test (`slippedItems`) + `SlipDetectorTests` | ✅ |
| Source freshness (calendar/Gmail/HealthKit last-synced) displayed | same test (`sources`) | ✅ |
| Generated with Gmail/HealthKit absent, missing sources noted (never implies completeness) | `BriefingAssemblerTests.test_briefingMarksAbsentSourcesExplicitly` | ✅ |
| *(edge)* fully-empty day → coherent briefing, nil top priority, sources still marked | `BriefingEdgeCaseTests.test_emptyDay_producesCoherentBriefing_nilTopPriority` **(new)** | ✅ |
| *(edge)* "due today" honors the injected calendar's timezone, not a hardcoded zone | `BriefingEdgeCaseTests.test_dueToday_honorsInjectedCalendarTimezone` **(new)** | ✅ |
| Real calendar events actually appear from live Google | — | 🔵 OAuth-live |

### Evening Capture
| Criterion | Test(s) | Status |
|---|---|---|
| Reconciles captured reality against the day's plan (marks tasks done/skipped) | `EveningCaptureTests.test_captureWritesDailyLogProgressAndOpenLoop` | ✅ |
| Updates DailyLog / GoalProgress / OpenLoop without a form | same test | ✅ |
| Second capture same day corrects rather than duplicates | `EveningCaptureTests.test_secondCaptureSameDayRevisesDailyLogRatherThanDuplicating` | ✅ |
| Completes in under one voice/tap interaction (common case) | `VoiceCaptureTests.test_singleInteraction_recordConfirmApplied` | 🟡 logic ✅; real "feels fast"/adherence is real-use |

### Goal Planning
| Criterion | Test(s) | Status |
|---|---|---|
| Distinct plans from a shared schema (not hardcoded) | `PlaybookDistinctnessTests` | ✅ |
| Produces an approve/edit/reject schedule proposal BEFORE any calendar write (zero writes at preview) | `SchedulePreviewTests` (asserts `writeCallCount == 0`) + `PlanProposalCoordinatorTests` | ✅ |
| Approving the plan → exactly one agent event per task, idempotent | `CalendarProposalTests.test_approvingPreviewProposals_createsExactlyOneEventEach_idempotent` | ✅ |
| A rejected plan does not silently retry (dismiss/expire never execute) | `StateMachineTests.test_dismissed_neverExecutes`, `test_expired_neverExecutes` | ✅ |
| *(edge)* year-long horizon stays bounded, well-formed, deterministic | `PlannerScaleAndConflictEdgeTests.test_yearLongHorizon_staysBoundedWellFormedAndDeterministic` **(new)** | ✅ |

### Ops Inbox / Proposals
| Criterion | Test(s) | Status |
|---|---|---|
| Every Proposal actionable: approve / dismiss / snooze / mark-as-wrong / schedule / remember | `StateMachineTests`, `RejectionAndAlertTests`, `WeeklyReviewBatchTests`, `HandlerExecutionTests` (per-type handlers) | ✅ |
| Approving executes ONLY the described action — no inferred follow-up | `StateMachineTests.test_approve_invokesOnlyItsOwnHandler` (spy per type) + `RegistryAuditTests` | ✅ |
| Dismissed / snoozed / expired never execute | `StateMachineTests` (three dedicated tests) | ✅ |
| No Proposal auto-resolves to approved; expiry drops, not actions | `StateMachineTests.test_expired_neverExecutes` | ✅ |
| Batch (Weekly Review) approve creates exactly approved events; individual dismiss excludes only that | `WeeklyReviewBatchTests` | ✅ |

### Voice
| Criterion | Test(s) | Status |
|---|---|---|
| User can interrupt playback | `VoiceConversationControllerTests.test_interruptDuringPlayback_returnsToIdle` + `TTSRouterTests.test_interruption_haltsWithinLatencyTarget` (<100ms state flip) | 🟡 logic ✅; real audio latency 🔵 device |
| Low-confidence transcription requires confirmation before a Proposal/memory entry | `VoiceConversationControllerTests.test_lowConfidence_parksAndSendsNothing` (+ confirm/reject) | ✅ |
| Transcript not persisted unless confirmed/approved | `test_voiceQATurn_persistsNoMemory` + `VoiceCaptureTests.test_nothingPersistsBeforeConfirmation` | ✅ |
| ElevenLabs failure falls back to system voice without breaking the turn | `ElevenLabsTTSTests.test_realElevenLabsFailure_routerFallsBackToSystemVoice` | ✅ |
| Real mic capture / Apple Speech quality / 0.6 confidence calibration / real audio out | — | 🔵 device |

### Weekly Review
| Criterion | Test(s) | Status |
|---|---|---|
| Correctly categorizes completed / slipped / next-week per goal | `WeeklyReviewTests.test_categorizesCompletedSlippedAndNextWeekPerGoal` | ✅ |
| Runs even with degraded sources, degraded sources explicitly noted | same test (`degradedSources`) | ✅ |
| Next-week bucket → batch of create-event Proposals (one Sunday plans the week) | `WeeklyReviewBatchTests` + `PlanProposalCoordinatorTests` | ✅ |
| Generated ON the configured day (Sunday default, user-configurable) | — (no scheduler; assembler is day-agnostic and user-triggered) | 🟡 → actionable gap #1 |

### Conflict Detection
| Criterion | Test(s) | Status |
|---|---|---|
| Flags true overlaps between fixed-flexibility tasks at minimum | `ConflictDetectorTests.test_fixedFixed_blockBlock_isHardConflict` | ✅ |
| Movable/optional flagged per configured policy (block/warn/allow), not always hard-blocked | `ConflictDetectorTests` (fixed/movable, movable/optional, allow/allow-not-flagged) | ✅ |
| Cross-goal only; adjacency/non-overlap not flagged; deterministic yield selection | `ConflictDetectorTests` (sameGoal-ignored, adjacent, determinism) | ✅ |
| *(edge)* three mutually-overlapping goals → all 3 pairwise conflicts, order-independent | `PlannerScaleAndConflictEdgeTests.test_threeGoalsMutuallyOverlapping_surfaceAllThreePairwiseConflicts` **(new)** | ✅ |

### Cross-cutting safety rules (traced in REVIEW_REPORT; re-confirmed green here)
| Rule | Test(s) | Status |
|---|---|---|
| LLM propose-tools can only enqueue a pending Proposal (adversarial "add it now") | `GoldenFixtureTests.test_proposeContainment_addToCalendarNow…` + `RegistryAuditTests` | ✅ |
| Agent-calendar writes only; idempotent | `CalendarProposalTests.test_duplicateKey_yieldsExactlyOneEvent` | ✅ |
| Memory append-only; conflicts stay explicit | `MemoryLifecycleTests` + `MemoryDepthTests` (deep chain) **(new)** | ✅ |
| Secrets never logged; audit carries no tokens | `ModelCallLoggingTests`, `RedactingLoggerTests` | ✅ |
| Gmail dedupe + mark-as-wrong downranking | `GmailScanCoordinatorTests` | ✅ |
| Shortcut intake: classified pending proposal; malformed/stale dropped | `ShortcutIntakeTests` | ✅ |

**Coverage summary: 34 mapped criteria/clauses → 28 fully covered ✅ · 3 partial 🟡 (logic covered, real-use facet gated) · 3 device/account-gated 🔵.** No PRD per-flow acceptance criterion has zero host-side coverage. The only true *unbuilt* gaps are outside the per-flow criteria (Non-Functional section — see §4).

---

## 3. New Tests Added (this phase) + Bugs

Five host-side edge-case tests were added (TDD conventions of the repo — pure, deterministic, injected clock/calendar), targeting the highest-risk untested edges: empty states, timezone/day boundaries, revision chains at depth, huge plans, and N-way concurrency of conflicts.

| # | Test | Target | What it locks down |
|---|---|---|---|
| 1 | `BriefingEdgeCaseTests.test_emptyDay_producesCoherentBriefing_nilTopPriority` | DailyLoopTests | Empty day → no phantom headline (`topPriority == nil`), all buckets empty, sources still present-and-marked, Codable round-trips |
| 2 | `BriefingEdgeCaseTests.test_dueToday_honorsInjectedCalendarTimezone` | DailyLoopTests | "Due today" windows against the *injected* calendar's timezone (UTC due, UTC-5 not due for the same 23:30-UTC task) — guards against a hardcoded-zone regression |
| 3 | `MemoryDepthTests.test_deepCorrectionChain_keepsOneActive_preservesFullHistory` | DataTests | 6-deep revision chain: history keeps all 6 (values v0…v5), exactly one active, monotonic numbering, default query resolves to newest |
| 4 | `PlannerScaleAndConflictEdgeTests.test_yearLongHorizon_staysBoundedWellFormedAndDeterministic` | GoalsTests | 53-week plan (>100 tasks) stays bounded (`count == weeks×perWeek`), every task well-formed (`latest ≥ earliest`, positive duration, in-range week), fully deterministic on replan |
| 5 | `PlannerScaleAndConflictEdgeTests.test_threeGoalsMutuallyOverlapping_surfaceAllThreePairwiseConflicts` | GoalsTests | N-way (>2) conflicts: 3 goals → exactly C(3,2)=3 pairwise conflicts, no dupes, order-independent |

**Bugs found: NONE in product code.** One test (#4) initially failed on my own arithmetic assertion (`365 ÷ 7 = 52.14` rounds **up to 53** weeks, not 52) — the planner's behavior was correct and bounded; I corrected the test expectation. No product source was changed in this phase. All 5 new tests pass; full suite is 260/260, stable across 3 runs.

---

## 4. Actionable Gaps (host-side-writeable, not device/account-gated)

These are genuine gaps that could be closed without a device or paid account. They are **outside every phase's acceptance criteria** (they live in the PRD's *Non-Functional Considerations*, which no phase in `PROJECT_PLAN.md` scoped as a deliverable), so they are honest v1-scope shortfalls rather than regressions:

1. **Weekly Review is user-triggered, not scheduled on the configured day.** `ReviewCadence` exists as playbook data but is not wired to any scheduler; the assembler is day-agnostic. *Actionable*: build a cadence/notification trigger (and a host-side test that, given a configured Sunday + `now`, the "is it review day" predicate fires correctly). Note the *delivery* (a real local notification firing) is UNUserNotificationCenter/device-gated, but the day-selection predicate is host-testable.
2. **No notification-scheduling layer at all.** PRD Non-Functional "Notifications" (morning/evening prompts, Ops Inbox alerts, weekly review, slipped-goal nudges, quiet hours, per-category mute) has no implementation (`grep` for `UNUserNotification`/scheduler is empty). *Actionable*: a testable `NotificationPolicy`/scheduler (frequency, quiet-hours windows, per-category enable) with host-side tests on the policy math; the actual OS scheduling is device-gated.
3. **No data export/delete.** PRD Non-Functional privacy requires explicit export/delete covering memory (incl. revision history), proposals, logs, source refs, and local-only data. No implementation found. *Actionable*: an export serializer + a delete/erase path, both fully host-testable against an in-memory container (assert export contains all revisions; assert delete removes rows / tombstones correctly).

These are flagged for the user/next phase as a scoping decision — none blocks the core loop, and none was promised by a phase acceptance criterion.

**Expected (NOT actionable here) — device/account-gated**, per the consolidated checklist in `IMPLEMENTATION_LOG.md` §"CONSOLIDATED REMAINING-VERIFICATION CHECKLIST": live Google OAuth, HealthKit on device, iMessage Shortcuts on device, live Gemini behavior, real voice audio/quality/calibration, CloudKit iPhone↔Mac sync (paid Apple Developer Program), and a signed Mac run. **Subjective/real-use** (verifiable only by living with the app): "voice feels good to talk to," evening-capture adherence, whether the briefing feels trustworthy, and whether live Gemini stays grounded.

---

## 5. Manual QA Checklist (on-device, for a non-technical user)

Do these in order after first install. Each step says what to tap and what you should see. If a step's "You should see" doesn't happen, note the step number — that's the bug report.

**Setup (one-time)**
1. **First launch.** Open the app. *You should see:* the app opens on the **Briefing** tab with tabs along the bottom (Briefing, Capture, Review, Inbox, Goals, Ask, Memory, Integrations). Nothing crashes; empty sections read as "nothing yet," not blank errors.
2. **Connect Google.** Go to **Integrations → Connect Google**, sign in, approve calendar + Gmail read access. *You should see:* the Google consent window; afterward Integrations shows Google as connected with a "last synced" time. (Requires your own Google Cloud OAuth client per `docs/GOOGLE_SETUP.md`.)
3. *(Optional)* **Enable the assistant.** If you added a `GEMINI_API_KEY`, the **Ask** tab is active. Without it, Ask shows "Assistant unavailable — add GEMINI_API_KEY" (that's expected, not a bug).

**Goals & scheduling**
4. **Create a goal.** **Goals → +**, pick **Triathlon Training** (or Job Search), answer the short intake questions, save. *You should see:* a goal detail screen with milestones, tracked metrics, and a 7-day schedule preview labeled "inspect only — not written to calendar."
5. **Propose the schedule.** On the goal, tap **"Propose schedule to Ops Inbox."** *You should see:* a confirmation that proposals were added — and **nothing yet on your real calendar** (this is the safety rule: it only proposes).
6. **Approve in the Inbox.** Go to **Inbox**. *You should see:* pending calendar-event proposals with plain-language rationale. Approve one (or select several → batch approve). *You should see:* it moves out of pending; only now does the event appear on your **"Personal Ops Agent"** calendar (never your personal calendar).
7. **Conflict scenario.** Create a *second* goal whose blocks overlap the first (e.g. a Job Search prep block on the same Saturday morning as a training long-ride). Propose its schedule. *You should see:* in the Inbox, a **conflict** proposal that names both blocks and offers to move the more-flexible one — it surfaces the clash, it does not silently double-book.

**Daily loop**
8. **Morning briefing (next morning, or reopen the app).** Open **Briefing**. *You should see:* today's real events and agent events listed **separately**, goal tasks due today, any slipped items, "yesterday" summary if present, and a **source-freshness** row (calendar synced at…, Gmail scanned at…, HealthKit read at…). If Gmail/Health aren't connected it says so — it never pretends completeness.
9. **One-tap complete.** On a due task in the briefing, tap **complete** (or **skip**). *You should see:* it marks done immediately; the next briefing reflects it. If a write fails you get a visible alert (not a silent no-op).
10. **Evening capture (typed).** **Capture** tab: mark what you did, add a note and an open loop, save. *You should see:* it saves in one screen (no long form). Reopen Capture the same day and change the note — *you should see* it **corrects** the day's log, not add a duplicate.
11. **Evening capture (voice).** On **Capture**, use **"Capture by voice,"** say e.g. "done with the swim, skipped strength, remember to book a massage," review, confirm. *You should see:* a one-step review then save; nothing is stored until you confirm.

**Signals & memory**
12. **Gmail scan.** **Integrations → Scan now** (Gmail must be connected). *You should see:* any plan-like emails become **pending proposals** in the Inbox (an interview time, a receipt), each showing its source. Scanning the same thread twice does **not** create a duplicate.
13. **Mark one wrong.** On a Gmail-derived proposal you don't want, choose **mark-as-wrong**. *You should see:* it's dismissed; similar future emails from that sender/subject shape get suppressed rather than re-proposed.
14. **Forwarded text (Shortcuts).** Set up the "When I get a message" automation from `docs/SHORTCUTS_SETUP.md`, then forward yourself a text like "Dinner Fri at 7pm." *You should see:* it quietly becomes a **pending** proposal in the Inbox (never auto-added). A blank or very old forward produces nothing (dropped, not guessed).
15. **Ask a memory question.** **Ask** tab (needs the assistant): type or speak "what did I decide about the Acme offer?" *You should see:* a grounded answer if it's in memory, or an honest "I don't know" if it isn't — never a made-up answer. If it wants to change anything, it only ever puts a proposal in your Inbox.
16. **Interrupt the voice answer.** Ask a longer question by voice and, while it's speaking, tap to **interrupt**. *You should see:* playback stops promptly and it returns to idle, ready for your next turn.

**Weekly review & Mac**
17. **Weekly review.** Open **Review**. *You should see:* per goal, what you completed, what slipped, and next week's tasks — with any degraded data source noted. Tap **"Plan next week to Ops Inbox."** *You should see:* next week's blocks arrive as a **batch** of pending proposals you can approve in one Inbox session.
18. **Mac launch** *(optional; needs a Mac build)*. Build & run **PersonalOpsAgentMac** (`docs/MAC_SETUP.md`). *You should see:* the same tabs and core loop. Connect Google separately on the Mac (per-device sign-in by design). Note: iPhone↔Mac **sync** only works after enrolling in the paid Apple Developer Program and enabling CloudKit (`docs/CLOUDKIT_SETUP.md`) — until then each device is local-only, which is expected.

---

## 6. Overall QA Verdict

**READY FOR USER (ON-DEVICE) QA. No blockers.**

- All automated suites pass and are non-flaky: **260 / 260** package unit tests (255 shipped + 5 new edge-case), iOS `xcodebuild test` **TEST SUCCEEDED**, macOS **BUILD SUCCEEDED** on a certless checkout.
- Every PRD per-flow acceptance criterion has host-side coverage; the safety-critical negatives (nothing auto-executes, memory never destroys history, secrets never logged, agent-calendar-only writes) hold structurally and are proven by tests re-verified this phase.
- The five new edge-case tests found **no product bugs** — the empty-day briefing, timezone windowing, deep revision chains, year-long plans, and N-way conflicts all behave correctly and deterministically.
- Remaining work is exactly the **expected** device/paid-account verification checklist (`IMPLEMENTATION_LOG.md`) plus three **unbuilt Non-Functional features** (notification scheduling, data export/delete, scheduled-day weekly review) that no phase acceptance criterion required — flagged in §4 as a scoping decision for the user, not as ship blockers for the core loop.

The next step is the user's on-device pass using the §5 checklist (with their own Google OAuth client and, for sync, a paid Apple account).
