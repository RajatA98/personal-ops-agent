# Locked Decisions — Personal Ops Agent

**Status**: Complete
**Last Updated**: 2026-07-10

These decisions are treated as fixed during implementation. Changing any of them after this point means re-opening Plan, not a mid-build pivot. See `factory/artifacts/PRESEARCH.md` for the full discussion each of these is drawn from.

## 1. Product Shape

**Decision**: Single-user native Apple app — an iOS app plus a macOS companion app, sharing one SwiftUI codebase, both signed into the same iCloud account. No backend, no accounts, no App Store listing.

**Rejected alternatives**:
- Multi-user/shareable product — rejected, explicitly out of scope per the Problem Summary; would add auth, multi-tenancy, and privacy-isolation complexity for a need that doesn't exist.
- Web app / cross-platform (Flutter, React Native) — rejected because the app leans on iOS-native APIs (HealthKit, Keychain, on-device Speech, Shortcuts) that a cross-platform framework would still need native bridges for, with no upside since there's no Android target.
- A literal browser-based web app for the Mac side — rejected in favor of a native Mac app. A web app would mean either a fragile local web server running on the Mac or standing up real hosting, which reintroduces the backend/third-party-hop problem rejected in #3. A native Mac app with iCloud sync is both simpler to build and closer to how Apple's own ecosystem (Notes, Reminders, Messages) already works across a user's own devices.

## 2. Platform & Distribution

**Decision**: Native Swift/SwiftUI. Sideloaded via free Apple ID (no paid Apple Developer account, no App Store).

**Rejected alternatives**:
- Flutter — see Product Shape above.
- Paid Apple Developer account ($99/year) upfront — rejected for now on cost grounds; free-tier's 7-day resign cycle is an accepted, reversible tradeoff. Revisit if it becomes a real annoyance.
- App Store distribution — unnecessary for a single-user app; rejected to avoid review process and public listing entirely.

## 3. Backend & Cross-Device Sync

**Decision**: No backend we run or host. Cross-device sync between the user's iPhone and Mac is handled by **CloudKit** (Apple's private per-iCloud-account storage), via SwiftData's built-in CloudKit integration.

**Rejected alternatives**:
- Thin backend server (holding OAuth tokens, proxying API calls) — rejected because it adds hosting cost, an extra data-custody hop for sensitive data (Gmail/Calendar content) through a company we'd have to run, and complexity with no corresponding benefit.
- Literal web hosting for a browser-based Mac experience — same rejection as above; see Product Shape.
- **Important distinction, not a contradiction of "no backend"**: CloudKit is not a server we build or operate — it's Apple's managed private database tied to the user's own iCloud account, the same mechanism Notes/Reminders/Messages use to sync between a user's own devices. No new company gets access to the data; the trust boundary is the same Apple ID the user already has.
- **Explicit tradeoff accepted**: still no true background/overnight processing while both devices are asleep, and no sync to any device outside the user's own iPhone/Mac. If broader needs emerge later, this decision gets revisited — not silently worked around.
- **Platform-specific gaps to resolve in Plan**: some integrations are iOS-only (HealthKit; Shortcuts-based iMessage capture may behave differently on Mac) — the Mac app will consume synced data and results from these (e.g., pacing insights already computed on iPhone) rather than re-implementing iOS-only capture natively on day one. Google OAuth token sharing between devices (via iCloud Keychain sync, vs. each device authorizing separately) is a Plan-level detail, not resolved here.

## 4. Calendar / Gmail Integration Pattern

**Decision**: Direct Google REST API integration (OAuth via `ASWebAuthenticationSession`, tokens in iOS Keychain) combined with native LLM tool-calling (not MCP).

**Rejected alternatives**:
- MCP (Model Context Protocol) — rejected because its core value (multiple host apps sharing one tool server) doesn't apply to a single-client app, and hosting an MCP server would either not work well under iOS sandboxing (local) or reintroduce a backend and a third-party data hop (remote) — contradicting the no-backend decision.

**Safety-critical rule (locked, not just a recommendation)**: tools exposed to the LLM are split into read tools (execute immediately) and propose tools (write only to the local Proposal queue). The LLM is never given a tool that can directly mutate the real calendar or send anything on the user's behalf. This is an architectural constraint that implementation must enforce, not a prompt-level suggestion.

**Also locked**: scheduled flows (Morning Briefing, Evening Capture, Weekly Review) use deterministic Swift-triggered data assembly, not LLM-initiated tool calls. Voice/free-form Q&A uses agentic tool-calling.

## 5. Local Data Storage

**Decision**: SwiftData.

**Rejected alternatives**:
- Core Data — more mature but far more boilerplate, no advantage over SwiftData for this use case.
- GRDB/raw SQLite — offers more explicit control, better native fit for the memory system's append-only revision pattern, but costs more code and loses free SwiftUI data binding across the rest of the app (which is most of the UI surface), and no built-in CloudKit sync path. Documented as the fallback specifically for the memory subsystem if SwiftData's query/migration behavior becomes a real blocker during implementation — not a fallback for the whole app.

**Updated from Presearch**: SwiftData's CloudKit sync is now used (not deferred) — this is what powers the iPhone/Mac sync in decision #3. This was flagged in Presearch as SwiftData's least mature feature area, so it should be scoped as its own testable phase in Plan rather than assumed to work perfectly on the first pass.

## 6. Runtime Reasoning Model

**Decision**: Gemini (Flash tier) as the default, behind a swappable `ReasoningProvider` abstraction.

**Rejected alternatives**:
- Claude Haiku 4.5 — the initial recommendation (same vendor as Fable, strong tool-calling track record, prompt caching). Superseded by the data-exposure-surface argument: routing reasoning through Gemini keeps Gmail/Calendar-derived context within one company (Google) the user already trusts with that data, rather than adding a second (Anthropic). Combined with Gemini Flash's competitive cost, this won out.
- OpenAI GPT-5.x mini — not chosen; no distinguishing advantage over Gemini for this use case, would add a third vendor rather than consolidating.
- Apple on-device Foundation Models — rejected as the primary engine; too weak for the actual judgment calls this app needs (weekly synthesis, conflict tradeoffs, plan generation). Left open as a possible future cheap pre-filter (e.g., "does this email look plan-like"), not part of v1.
- **Explicit tradeoff accepted**: Gemini's tool-calling is somewhat less battle-tested than Claude's for this exact agentic-proposal pattern. Mitigated by the provider abstraction — swappable later without a rewrite if this becomes a real problem.

## 7. Voice Stack

**Decision**: On-device speech-to-text (Apple Speech framework) + cloud text-to-speech (ElevenLabs).

**Rejected alternatives**:
- ElevenLabs for both STT and TTS — rejected for STT specifically: would send raw voice audio off-device for every interaction, a meaningfully larger privacy footprint than necessary when Apple's on-device recognition is already good and free.
- Apple `AVSpeechSynthesizer` for TTS — rejected as the primary choice; sounds noticeably synthetic, and voice quality is a real trust/engagement factor for a daily conversational assistant, not cosmetic. Kept as the swappable fallback if ElevenLabs cost/latency becomes a problem.

## 8. Auth / OAuth

**Decision**: No app-level login (single user, no accounts). Google OAuth (user-owned Cloud project/client, "Testing" publishing status) for Calendar/Gmail authorization only. Tokens in Keychain, one-time consent on first launch, silent refresh thereafter.

**Rejected alternatives**: N/A — this is required by Google's API regardless of user count; there was no viable alternative to skip Google's consent flow for Calendar/Gmail access.

## 9. iMessage & HealthKit

**Decision**: iMessage via a user-configured Shortcuts personal automation handing text to an app-exposed URL scheme/App Intent (no passive background reading). HealthKit via standard read-only permission request for sleep/recovery-adjacent metrics.

**Rejected alternatives**: Any form of passive/background Messages reading — not offered as an option; iOS does not permit it regardless of implementation effort.

## 10. Mac Companion App

**Decision**: A native macOS app, sharing the SwiftUI codebase and business logic with the iOS app, presenting the same core loop (Morning Briefing, Evening Capture, Goals, Ops Inbox, Memory Q&A, Voice). Data syncs automatically via CloudKit (see #3).

**Rejected alternatives**: Browser-based web app — see Product Shape (#1) and Backend (#3).

**Scope note**: voice (on-device STT + ElevenLabs TTS) works on Mac largely unchanged, since both are platform-agnostic (Mac has a mic/speakers, and ElevenLabs is a cloud API). HealthKit has no direct Mac equivalent — Mac-side pacing insights are consumed as already-synced data from the iPhone, not fetched natively. iMessage/Shortcuts handling on Mac is a Plan-level detail to confirm, not assumed identical to iOS.

## Known Risk Carried Into Plan

Concentration risk: five real external integrations (Calendar, Gmail, iMessage/Shortcuts, HealthKit, ElevenLabs) plus a versioned memory system plus an agentic tool-calling layer plus a second app target (Mac) synced via CloudKit, in one build effort. This is more surface area than the original iOS-only scope, not less. The Plan phase must sequence this deliberately — e.g., a strong recommendation is to get the iPhone app's core loop fully working and tested first, then extend to Mac via CloudKit sync as its own phase, rather than building both platforms in parallel from day one.
