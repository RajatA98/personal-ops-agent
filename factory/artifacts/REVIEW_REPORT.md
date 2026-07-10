# Review Report — Personal Ops Agent

**Status**: Complete
**Last Updated**: 2026-07-10
**Reviewer**: Independent code review (Project Factory Review phase). This code was reviewed with fresh, skeptical eyes; the reviewer did not write it.

---

## Summary Verdict

- **Locked-decision alignment**: **ALIGNED.** No drift found. No rejected technology (no MCP, no backend/server, no Flutter/web), correct minimal OAuth scopes (`calendar.readonly` + `calendar.app.created` + `gmail.readonly`), SwiftData + CloudKit-shaped schema, Gemini behind a genuinely provider-neutral `ReasoningProvider`, per-device OAuth, on-device STT + ElevenLabs TTS. The one hard external constraint (CloudKit needs a paid Apple Developer account, mutually exclusive with free-tier sideloading) is surfaced honestly rather than hidden.
- **Safety**: **SAFE.** All six non-negotiable rules were verified against the *code*, not the log's claims, and each holds structurally. The `ApprovalGrant` capability is genuinely unforgeable; `ProposalEngine.enqueue` is the only reachable write seam for the LLM; calendar writes are pinned to the agent calendar by both a code guard and the OAuth scope; memory is append-only with no destructive delete anywhere; there is no send path or send scope; secrets never reach a log sink and the audit schema has no field that could carry one.
- **Ship-ready**: **YES (blockers cleared in commit `6a0ed41`).** Originally NO for two reasons, both now fixed: (1) the documented macOS build command failed in a clean environment (code-signing/entitlements) — the Mac Debug config now signs ad-hoc and the exact command succeeds on a clean checkout; and (2) a real cross-phase integration gap — the deterministic *proposal-generation* flows (goal-plan → schedule, Weekly Review → batch, cross-goal conflicts, Gmail-derived signals) were built and unit-tested but had **no user-reachable trigger in the shipped UI** — all four are now wired to UI actions and covered by integration tests. The safety model was and remains intact; the product loop is now fully wired end-to-end. See per-finding dispositions below.

**Test-suite verification (run by the reviewer):**
- `cd Packages/PersonalOpsKit && swift test` → **250 / 250 passed**, 0 failures (matches the claimed count).
- `xcodebuild build -project PersonalOpsAgent.xcodeproj -scheme PersonalOpsAgentMac -destination 'platform=macOS'` → **BUILD FAILED** (signing/entitlements — see Critical-1). With `CODE_SIGNING_ALLOWED=NO` the same target **builds successfully**, confirming the failure is signing-environment, not a code defect.

**Post-fix verification (commit `6a0ed41`):**
- `cd Packages/PersonalOpsKit && swift test` → **255 / 255 passed**, 0 failures (250 prior + 5 new: `PlanProposalCoordinatorTests` ×4, `PromptLibraryTests.test_everyPrompt_resolvesInBundle` ×1). The propose-containment (`GoldenFixtureTests`) and registry-audit (`RegistryAuditTests`) safety tests pass unchanged.
- `xcodebuild build … -scheme PersonalOpsAgentMac -destination 'platform=macOS'` → **BUILD SUCCEEDED** on this clean environment with no development certificate (ad-hoc Debug signing).
- `xcodebuild test … -scheme PersonalOpsAgent -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.2'` → **TEST SUCCEEDED**.

**Counts**: Critical **1**, Major **2**, Minor **3**.

**Three most important findings (one line each):**
1. (Critical) macOS build fails as documented — `PersonalOpsAgentMac` entitlements require a development signing certificate absent in a clean environment; code compiles clean without signing.
2. (Major) The core "propose" loop is unreachable end-to-end: goal-plan scheduling, Weekly-Review batch, conflict detection, and Gmail signals never route to `ProposalEngine.enqueue` from any shipped view.
3. (Major) Gmail-derived signals (Phase 4B) specifically have no foreground trigger — `RootView` never passes `gmail`/`gmailMetadata` into `IntegrationsSettingsView`, so the "Scan now" section never renders.

---

## What Was Verified Clean (Safety-Rule Trace)

Each rule was traced from the LLM/tool boundary to the side-effect, reading the actual source.

**Rule 1 — the LLM never gets a tool that mutates real state. CONFIRMED CLEAN.**
- Trace: `Agent/ProposeTools.swift` — every one of the 5 propose tools ends in `ctx.engine.enqueue(proposal)` with `status: .pending` and returns a `pending_user_approval` receipt. None calls `approve`, a handler, or a client. Read tools (`Agent/AgentTools.swift`) are side-effect-free.
- The write seam is genuinely singular: `ProposalEngine.enqueue`/`enqueueBatch` (`Proposals/ProposalEngine.swift:91,100`) only insert a pending row. Execution happens only in `approve(...)` (`:123`), which is the sole minter of an `ApprovalGrant`.
- **`ApprovalGrant` is unforgeable**: `public struct ApprovalGrant` with a `fileprivate init` (`ProposalEngine.swift:18-21`). Declaring an explicit init suppresses the implicit memberwise initializer, so *no* code outside `ProposalEngine.swift` can construct one. Verified by grep: the only construction site is `ProposalEngine.swift:140`. **No test backdoor** — there is no `@testable import Proposals` anywhere (tests import it normally), and the sole test reference (`ProposalsTestSupport.swift:45`) is a spy handler *receiving* a grant parameter, not constructing one. Every `ProposalHandler.execute` requires the grant (`ProposalHandler.swift:87`), enforced by the compiler.
- The golden fixtures backing this are real, not tautological: `RegistryAuditTests.test_everyProposeTool_onlyCreatesPendingProposal…` drives all 5 propose tools and asserts 5 pending proposals + `writeCallCount == 0`; `GoldenFixtureTests.test_proposeContainment_addToCalendarNow…` runs the adversarial "add it to my calendar right now" and asserts exactly one pending proposal and zero real writes.

**Rule 2 — agent calendar writes only, never a real calendar. CONFIRMED CLEAN.**
- `Integrations/Calendar/GoogleCalendarRESTClient.swift`: every write path (`createEvent :104`, `updateEvent :123`, `deleteEvent :132`) first calls `requireAgentCalendar(for:) :143`, which resolves the agent calendar ID and **throws** `AppError.integration(.unavailable("Refused write to a non-agent calendar"))` for anything that isn't the resolved agent ID or the `"agent"` sentinel. The URL is always built from the resolved `agentID`, never the requested ID.
- Belt-and-suspenders: the OAuth scope is `calendar.app.created` (verified in `GoogleOAuthConfig`), which makes writes to the user's real calendars structurally impossible at Google's side even if the code guard were bypassed. `calendar.readonly` covers reads. Idempotency (caller-seeded event ID → 409-treated-as-success) is real and tested (`CalendarProposalTests.test_duplicateKey_yieldsExactlyOneEvent`: 1 event, `writeCallCount == 2`).

**Rule 3 — memory append-only. CONFIRMED CLEAN.**
- `Data/MemoryStore.swift`: `correct(_:) :55` copies value fields into a fresh revision (`makeRevisionCopy()`), stamps the old row `supersededAt`/`supersededByAppID` (audit fields only — the old row's *value* is never mutated), and never deletes. `expire(_:) :83` sets `expiresAt` but leaves the row in history. There is **no `context.delete` of any memory entity anywhere** in `Sources/` (grep: the only `.delete(` calls are `tokenStore.delete` in `GoogleAuthenticator` — Keychain token removal on disconnect, which is correct).
- Backed by genuine tests: `MemoryLifecycleTests` proves n+1 creation with n preserved, expiry exclusion-but-retained-in-history, and — notably — that correcting one side of a conflict does *not* collapse the conflict to an arbitrary winner (`resolve` returns `.conflict`).

**Rule 4 — nothing auto-sent. CONFIRMED CLEAN.**
- No `gmail.send`/`gmail.modify` scope requested; no send/POST-to-send path exists (grep for send paths returns only comments/unrelated identifiers). Gmail is `format=metadata` read-only (`GmailRESTClient`), storing message/thread IDs + dates + subject/sender headers only — within the PRD data boundary, never raw body.

**Rule 5 — secrets never logged. CONFIRMED CLEAN.**
- No `print`/`NSLog`/`os_log` anywhere in `Sources/` — logging is funneled through `Core/RedactingLogger.swift`, which scrubs registered secrets plus Bearer / `AIza…` / `GOCSPX-…` / `ya29.…` / email patterns before anything reaches the unified log.
- The model-call audit schema (`Core/ModelCallAudit.swift`) has **no token/header/prompt field by construction** — it stores purpose, input *categories*, provider name, a raw-external-content flag, tool names, and a round count. `ModelCallLoggingTests.test_auditSchema_carriesNoTokensOrHeaders` encodes it to JSON and asserts none of `authorization/bearer/apikey/token/aiza/?key=` appears. API keys ride the URL `key=` query in `GeminiReasoningProvider` (not a header) and are redacted as a backstop; ElevenLabs key is in the `xi-api-key` header and never logged. Both app composition roots register `config.secrets` with the logger at startup before anything runs.

**Rule 6 — degrade visibly, never silently. CONFIRMED (one minor exception, below).**
- `DailyLoop/BriefingModels.swift` + `BriefingAssembler.swift`: absent sources are represented as present-and-marked (`SourceFreshnessSnapshot.isAbsent`, `.unavailable`/`.permissionWithheld`), and `BriefingView.fetchCalendar` on any error returns empty events with a `lastSuccessfulSync: nil` freshness marker (surfaced, not dropped). `IntegrationStatusStore` drives visible reconnect prompts; a failed proposal approval keeps the proposal pending and surfaces the error in `OpsInboxView`. The one gap is a single interaction (Minor-1).

**Composition-root hygiene — CLEAN.** No fixture/fake leaks into production: there is no `import Fixtures` in any `Sources/` file, and neither app entry point references a Fake/Scripted/InMemory type except the widget's legitimate `.placeholder`. Both app roots use `KeychainTokenStore` (the `.live` default) and the durable `SwiftDataGmailMetadataStore` (the Phase-4B "deferred" wiring line is now present — `PersonalOpsAgentApp.swift:53-54`, `PersonalOpsAgentMacApp.swift:71-72`). Mac composition mirrors iOS and additionally injects the synced-HealthKit adapter.

---

## Findings

### Critical

**Critical-1 — macOS build fails as documented (signing/entitlements). CONFIRMED.**
- **Where**: `PersonalOpsAgent.xcodeproj/project.pbxproj` (PersonalOpsAgentMac target, `CODE_SIGN_STYLE = Automatic`, `ENABLE_HARDENED_RUNTIME = YES`, `CODE_SIGN_ENTITLEMENTS = App/PersonalOpsAgentMac.entitlements`); build command from the review contract and `CLAUDE.md`.
- **What**: `xcodebuild build … -scheme PersonalOpsAgentMac -destination 'platform=macOS'` fails with: *"PersonalOpsAgentMac has entitlements that require signing with a development certificate. Enable development signing…"*. The IMPLEMENTATION_LOG claims "macOS … BUILD SUCCEEDED."
- **Why it matters**: The documented/claimed-green build does not reproduce in an environment without a configured signing identity (CI, a fresh checkout, this review). Per the review rubric a failing documented build is Critical.
- **Important nuance (verified)**: This is **not a code defect.** With `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""` the same target builds successfully — the entire shared UI/Voice/Integrations/Data surface compiles and links for macOS. The failure is that a sandboxed + hardened-runtime Mac app cannot be signed without a development certificate, and no `DEVELOPMENT_TEAM` is pinned, so a machine lacking a cert (as the implementer's presumably had one) fails. The log's "SUCCEEDED" was true on a machine with a signing identity selected.
- **Suggested fix**: Either (a) document that the Mac build requires selecting a signing team once in Xcode / a cert in the environment (and adjust the "BUILD SUCCEEDED" claim to say "on a machine with a signing identity"), or (b) for CI/reviewer reproducibility, provide the `CODE_SIGNING_ALLOWED=NO` invocation as the canonical headless build check. No source change required.
- **DISPOSITION: FIXED** (commit `6a0ed41`). Root cause: the `com.apple.security.application-groups` entitlement requires a team-provisioned profile, which forced automatic signing to fail on a certless machine. The Mac target's **Debug** config now signs **ad-hoc** (`CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual`) against a new headless-safe `App/PersonalOpsAgentMac.Debug.entitlements` that keeps App Sandbox + network + microphone but omits the app group (the sole profile-requiring entitlement; nothing on the Mac depends on it today — the widget is iOS-only). The **Release** config is unchanged (automatic signing, full `PersonalOpsAgentMac.entitlements` with the app group at iOS parity) — that is the config the user signs properly. The exact documented command now returns **BUILD SUCCEEDED** on a clean, certless checkout; the Debug-vs-Release signing story is documented in `docs/MAC_SETUP.md`.

### Major

**Major-1 — Core proposal-generation flows are unreachable in the shipped UI (dead cross-phase wiring). CONFIRMED.**
- **Where**: `Sources/UI/GoalsView.swift`, `Sources/UI/WeeklyReviewView.swift`, `Sources/UI/RootView.swift`; the unused builders `Proposals/ScheduleProposalBuilder.swift`, `Proposals/WeeklyReviewProposalBuilder.swift`, `Proposals/ConflictProposalBuilder.swift`, `Goals/ConflictDetector.swift`.
- **What**: Grep confirms **no view calls** `ScheduleProposalBuilder`, `WeeklyReviewProposalBuilder`, `ConflictProposalBuilder`, `ConflictDetector`, or `ProposalEngine.enqueue`/`enqueueBatch`. `OpsInboxView` only *reads* pending proposals and approves/dismisses/snoozes (`OpsInboxView.swift:18,27,34,44`). `GoalsView` renders a schedule preview and explicitly says "real calendar events arrive via approved Phase 4A Proposals" (`GoalsView.swift:11-12`) but offers no action to create those proposals. `WeeklyReviewView` shows the "Next week" bucket and documents batch-proposal generation (`WeeklyReviewView.swift:13`) but never wires it.
- **Why it matters**: In the running app, the only reachable proposal *sources* are the Ask-tab Q&A propose-tools and the iOS Shortcuts App Intent. The four deterministic sources that make the Ops Inbox valuable — goal-plan scheduling, the Sunday Weekly-Review batch, cross-goal conflict detection, and email-derived signals — cannot be triggered by the user. The unit tests pass because they drive the builders/detector directly; the app-level seam that connects them to a button was deferred per-phase and never completed. This is precisely the "components exist but aren't connected in the app" gap flagged for scrutiny.
- **Suggested fix**: Add the missing UI actions: an "Add to Ops Inbox" action on the goal-plan preview (`ScheduleProposalBuilder` → `enqueueBatch`); a "Plan next week" action on Weekly Review (`WeeklyReviewProposalBuilder`); and run `ConflictDetector.detectAndBuild` when a goal plan is materialized / on briefing assembly so conflicts surface as proposals. Then add a light end-to-end UI test per flow.
- **DISPOSITION: FIXED** (commit `6a0ed41`). New `Proposals/PlanProposalCoordinator.swift` is the single testable seam the views call — it builds pending proposals and routes them through `ProposalEngine.enqueueBatch`, adding **no execution path** (every proposal is `.pending`; only Ops Inbox approval runs a handler). Wiring: `GoalsView`'s goal-plan preview gained a **"Propose schedule to Ops Inbox"** action (`ScheduleProposalBuilder.proposals` → `enqueueBatch`, and at the same seam `ConflictProposalBuilder.detectAndBuild` across all active goals so cross-goal collisions surface as `modify_goal_plan` proposals); `WeeklyReviewView` gained a **"Plan next week to Ops Inbox"** action (`WeeklyReviewProposalBuilder.nextWeekProposals` → `enqueueBatch`). Integration tests (`PlanProposalCoordinatorTests`) prove each fixture action lands pending proposals and writes nothing to the calendar, including the cross-goal-conflict surfacing and factKey re-run dedupe.

**Major-2 — Gmail-derived signals have no foreground trigger in the shipped app. CONFIRMED.**
- **Where**: `Sources/UI/RootView.swift:77-79` vs `Sources/UI/IntegrationsSettingsView.swift:27-28,42-43,70-71,148,172`.
- **What**: `IntegrationsSettingsView` gates its "Scan now" section on `if let gmail, let gmailMetadata` (`:70`), and only that section constructs `GmailScanCoordinator` (`:172`). But `RootView` instantiates the view with `IntegrationsSettingsView(status:controller:syncState:)` (`RootView.swift:77-79`), omitting `gmail`/`gmailMetadata` (both default `nil`). So the section never renders and `GmailScanCoordinator.scanNow` is never invoked. Background scanning is explicitly out of scope (foreground-only, per the plan), so this button is the *only* trigger — and it is unreachable.
- **Why it matters**: Phase 4B (Gmail → Proposals, dedupe, mark-as-wrong downranking) is fully built, wired into the composition-root environment (`integrations.gmail`/`gmailMetadata` exist), and unit-tested — yet ships dead. A user can never get an email-derived proposal.
- **Suggested fix**: Pass `gmail: integrations.gmail, gmailMetadata: integrations.gmailMetadata` at the `RootView` call site (the exact one-liner the Phase-4B log flagged as deferred). One line; the rest is already built and tested.
- **DISPOSITION: FIXED** (commit `6a0ed41`). `RootView` now constructs `IntegrationsSettingsView(status:controller:gmail:gmailMetadata:syncState:)`, passing `integrations.gmail` and `integrations.gmailMetadata`, so when Gmail is configured the "Scan now" section renders and `GmailScanCoordinator.scanNow` is reachable. The end-to-end scan → pending-proposal behavior is already proven by the existing `GmailScanCoordinatorTests` (the coordinator is the seam the button invokes); this finding was purely the missing composition-root wiring.

### Minor

**Minor-1 — One-tap complete/skip on the briefing swallows write failures silently. CONFIRMED.**
- **Where**: `Sources/UI/BriefingView.swift:176` — `} catch { return }`.
- **What**: If the `TaskActioner` write fails, the tap silently no-ops with no user feedback (the tap appears to do nothing). This is a narrow exception to Rule 6 (degrade *visibly*) — it doesn't write anything wrong, but it hides a failure from the user. Contrast `OpsInboxView`, which correctly surfaces `errorMessage`.
- **Suggested fix**: Surface a transient error state (as OpsInboxView does) instead of swallowing.
- **DISPOSITION: FIXED** (commit `6a0ed41`). `BriefingView` gained an `actionError` state and an alert; the one-tap complete/skip `catch` now sets a user-facing message (`AppError.userMessage` when available) instead of silently returning. The tap no longer no-ops invisibly (Rule 6 — degrade visibly).

**Minor-2 — `fatalError` on a missing bundled prompt resource. CONFIRMED (low risk).**
- **Where**: `Sources/Reasoning/PromptLibrary.swift:29` — `fatalError("Missing bundled prompt resource: …")`.
- **What**: If a prompt `.txt` is ever dropped from the SPM resource bundle, the app crashes at load instead of degrading. Prompts are bundled via `.process("Prompts")` so this is a programmer-error guard, but it is a hard crash surface in production code.
- **Suggested fix**: Prefer returning a typed error / a safe default prompt, or keep the `fatalError` but add a build-time test asserting every `Prompt` case resolves in `Bundle.module` (cheap insurance).
- **DISPOSITION: FIXED** (commit `6a0ed41`), via the "cheap insurance" option. Added an internal non-trapping `PromptLibrary.resourceURL(for:)` and a test `PromptLibraryTests.test_everyPrompt_resolvesInBundle` that asserts every `Prompt` case resolves in `Bundle.module` and fails *cleanly* if a `.txt` is ever dropped — so the `fatalError` in `load` is now a guarded last-resort programmer-error trap, not an unguarded production crash surface. Kept `fatalError` intentionally (a missing bundled prompt is an unrecoverable packaging error; a "safe default prompt" would silently degrade the model's grounding instructions, which is worse).

**Minor-3 — Non-test force-unwrap in a preview helper. CONFIRMED (acceptable).**
- **Where**: `Sources/UI/RootView.swift:95` — `try! DataStore.makeContainer(inMemory: true)` inside `PreviewSupport`.
- **What**: A `try!` in shipped (non-test) code. It is confined to a `#Preview`-only helper and documented as such, so it cannot execute in the running app. Noting for completeness; not worth changing unless previews are ever reused at runtime.
- **DISPOSITION: DEFERRED** (accepted as-is). The `try!` lives inside `PreviewSupport.seededContainer()`, called only from a `#Preview` block, which Xcode compiles into the app only for the canvas and never executes at runtime. The report itself grades it "acceptable / not worth changing". Changing it (e.g. `try?` + a placeholder container) adds no runtime safety and would only mask a genuine preview-setup failure from the developer, so it is intentionally left unchanged.

---

## Notes on Test Quality (spot-check)

The safety-critical tests are genuine, not mocked into meaninglessness:
- **Never-execute negatives** (`StateMachineTests`): iterate `ProposalType.allCases` with a spy per type; assert exactly one handler runs on approve and `executeCount == 0` for dismissed/snoozed/expired, plus that stale-approve *expires* rather than runs.
- **Idempotency** (`CalendarProposalTests`): duplicate idempotency key → `createdEvents.count == 1` with `writeCallCount == 2` (proves the store deduped, not the caller).
- **Propose-containment golden fixture** (`GoldenFixtureTests`): a real adversarial prompt asserting one pending proposal + zero real writes; the grounding checker has a teeth-proving negative test (`…flagsFabrication`).
- **Memory revision/conflict** (`MemoryLifecycleTests`): proves conflicts stay explicit and don't collapse to an arbitrary winner on correction.

Honest limitation (already acknowledged in the log, not a hidden gap): the LLM golden fixtures verify the *harness + checker* against a scripted provider — they do not prove live Gemini won't hallucinate. That is correctly documented as a live-only verification. Determinism is handled well throughout via an injected `Clock`/`Calendar` (no real-clock flakiness observed). The reviewer found **no PRD acceptance criterion with zero test coverage at the unit level**; the coverage gaps are at the *UI-integration* level (Major-1/-2), where the flows exist but aren't exercised end-to-end.

---

## Punch List (ordered by severity)

All items resolved in commit `6a0ed41` (Minor-3 deferred by design). Original items kept for traceability:

1. **[Critical-1] — FIXED.** Mac Debug config signs ad-hoc against a headless-safe Debug entitlements file; the documented `xcodebuild … -destination 'platform=macOS'` command now succeeds on a clean, certless checkout. Signing story documented in `docs/MAC_SETUP.md`.
2. **[Major-1] — FIXED.** Deterministic proposal sources wired via `PlanProposalCoordinator`: goal-plan preview → `ScheduleProposalBuilder` + `ConflictProposalBuilder.detectAndBuild` → `enqueueBatch`; Weekly Review → `WeeklyReviewProposalBuilder` → `enqueueBatch`. Integration tests per flow (`PlanProposalCoordinatorTests`).
3. **[Major-2] — FIXED.** `RootView` passes `gmail`/`gmailMetadata` into `IntegrationsSettingsView`; the "Scan now" trigger renders when Gmail is configured (behavior covered by existing `GmailScanCoordinatorTests`).
4. **[Minor-1] — FIXED.** `BriefingView` surfaces one-tap complete/skip failures in an alert instead of swallowing them.
5. **[Minor-2] — FIXED.** Added `PromptLibrary.resourceURL(for:)` + `test_everyPrompt_resolvesInBundle` as clean insurance behind the (retained, now-guarded) `fatalError`.
6. **[Minor-3] — DEFERRED (accepted as-is).** The preview-only `try!` in `RootView.PreviewSupport` never executes at runtime; changing it adds no runtime safety and would mask preview-setup failures.

**Bottom line**: The architecture is sound and the safety model is real and structurally enforced — this is a trustworthy "propose, don't act" core. Both v1 blockers are now cleared (commit `6a0ed41`): the Mac build has a working headless/ad-hoc signing story with the real entitlements preserved for Release, and all four deterministic proposal sources are wired to reachable UI actions with integration-test coverage. The core loop now works end-to-end for a user, and the safety-rule tests (propose-containment, registry-audit) pass unchanged.
