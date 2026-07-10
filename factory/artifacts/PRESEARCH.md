# Presearch — Personal Ops Agent

**Status**: Complete
**Last Updated**: 2026-07-10

This document captures the technology discussion held with the user before locking decisions. Each dimension below was discussed conversationally — options presented, tradeoffs explained, a recommendation given, and the user's call recorded. Final locking (with rejected-alternative rationale) happens in the Decide phase; this document is the research and discussion record that phase draws on.

## 1. Platform & Distribution

**Decision direction: Native iOS (Swift/SwiftUI), sideloaded via a free Apple ID — no App Store, no paid Apple Developer account for now.**

- Considered Flutter for cross-platform reach. Rejected: the app depends heavily on iOS-native capabilities (HealthKit, Keychain, on-device Speech framework, Shortcuts/App Intents) that Flutter would still need native Swift plugin bridges for — so Flutter adds an abstraction layer without a payoff, since there's no Android target.
- Avoiding the App Store and choosing a framework are independent decisions — sideloading (installing directly via Xcode) works the same regardless of framework, so this was a false coupling in the original ask.
- Free Apple ID signing expires every 7 days (requires reconnecting to a Mac to resign); a paid Apple Developer account ($99/year) extends this to a year and unlocks reliable HealthKit entitlements. User chose to start free, given a stated cost-consciousness, and upgrade later only if the 7-day cycle becomes a real annoyance. This is a reversible, low-stakes call.

## 2. Backend Architecture

**Decision direction: No backend. Fully on-device.**

- Single user, single device (for now) — no requirement to sync across multiple devices or process anything while the phone is off.
- iOS can call Google's Calendar/Gmail REST APIs and an LLM provider's API directly from the client, with OAuth tokens in Keychain — no server needed to broker any of this.
- This significantly simplifies privacy posture (no third data-custody hop) and removes hosting cost entirely.
- Revisit if the user ever wants multi-device sync or true background/overnight processing — out of scope for v1.

## 3. Calendar / Gmail Integration Pattern

**Decision direction: Direct Google REST API integration (OAuth via `ASWebAuthenticationSession`, tokens in Keychain) + native LLM tool-calling. No MCP.**

- MCP (Model Context Protocol) was considered explicitly, since the user asked about it. Rejected for this project: MCP's value is letting multiple different host applications share one tool server — this app is the only client that will ever exist, so that benefit doesn't apply. Running an MCP server would mean either a local long-lived process (not well supported on iOS's sandboxed model) or a remote/hosted server (which reintroduces a backend and an extra data-custody hop for Gmail content — contradicting the no-backend decision above).
- Instead: the LLM gets access to a small set of app-defined tools via native tool-calling (Claude/Gemini function-calling), executed locally in Swift. Same practical effect as MCP tool access, zero extra infrastructure.
- **Safety-critical design rule**: tools exposed to the LLM are split into read tools (execute immediately — `search_calendar`, `search_gmail`) and propose tools (`propose_calendar_event`, etc. — write only to the local Proposal queue, never the real calendar). The LLM is never given a tool capable of directly mutating real calendar state or sending anything — this makes "propose, don't auto-act" an architectural guarantee, not just a prompt instruction.
- Scheduled flows (Morning Briefing, Evening Capture, Weekly Review) use deterministic Swift-triggered data assembly rather than trusting the LLM to remember to fetch everything — more reliable and testable. Voice/free-form Q&A uses agentic tool-calling, since the data need varies per question.

## 4. Local Data Storage

**Decision direction: SwiftData** (with GRDB/SQLite as a documented fallback for the memory subsystem specifically, if SwiftData's query/migration behavior becomes a real blocker during implementation).

- Compared against Core Data (more mature, much more boilerplate, no clear advantage here) and GRDB/raw SQLite (more control, better fit for explicit versioned-revision queries, but no free SwiftUI binding and more code to write/verify).
- The memory system's versioning requirement (corrections as new revisions superseding prior ones, not destructive overwrites) is a data-modeling pattern — a `Revision` entity linked to a stable parent ID — achievable in SwiftData without needing raw SQL.
- SwiftData's tight SwiftUI integration reduces boilerplate across the rest of the app (Ops Inbox lists, Goal views, Briefing view), which is the majority of the UI surface.
- We don't need SwiftData's trickiest feature (CloudKit sync) since there's no multi-device requirement in v1 — this avoids its least mature area.

## 5. Runtime Reasoning Model

**Decision direction: Gemini (Flash tier) as the default, behind a swappable `ReasoningProvider` abstraction.**

- Claude Haiku 4.5 was the initial recommendation (same vendor as Fable, strong tool-calling track record, prompt caching).
- User raised Gemini given the existing Google Calendar/Gmail dependency. Clarified one point: there's no technical integration synergy between "Gemini the model" and "Google Calendar the API" — the app calls Google's REST APIs directly regardless of which LLM is used, so that specific argument doesn't hold.
- The argument that *does* hold: **reduced data-exposure surface**. The user already trusts Google with Gmail/Calendar content; routing the reasoning layer through Gemini keeps that content within one company rather than introducing a second (Anthropic or OpenAI) that also sees summarized email/calendar context. Combined with Gemini Flash's competitive cost, this was the deciding factor.
- Tradeoff acknowledged: Claude's tool-calling has a more proven track record for the kind of careful, constrained agentic pattern this app needs (Ops Inbox proposal tools). Given the swappable-provider architecture, this is a low-stakes, reversible choice — noted for Decide, not a blocker.

## 6. Voice Stack

**Decision direction: On-device speech-to-text (Apple's Speech framework) + cloud text-to-speech (ElevenLabs).**

- Split intentionally rather than picking one vendor for both:
  - **STT stays on-device (Apple)**: free, zero-latency, and — most importantly — raw voice audio never leaves the phone, which matters more for privacy than the output side of the conversation.
  - **TTS uses ElevenLabs**: Apple's native `AVSpeechSynthesizer` is free and on-device but sounds noticeably synthetic; since this app is meant to feel like a real daily conversational assistant (not a Siri-relay command dispatcher), voice quality is a genuine trust/engagement factor, not cosmetic. ElevenLabs' quality is a meaningful step up, at the cost of a paid usage-based API and a network dependency.
- Both sides are swappable behind a provider abstraction, matching the pattern used for the reasoning model — falling back to Apple's system voice for TTS is a config change if ElevenLabs cost/latency becomes a problem.

## 7. Smaller Integration Mechanics

- **Google OAuth**: user-owned Google Cloud project/OAuth client in "Testing" publishing status (never triggers Google's public-verification process, since there's only ever one user). Scopes: `calendar.events.owned` or `calendar.app.created` for write access to the agent-owned calendar only, plus `gmail.readonly`. One-time consent grant on first launch; token refresh happens silently thereafter via Keychain-stored tokens. This is authorization to access Google's data, not app-level login — the app itself has no sign-in screen, matching the single-user requirement.
- **iMessage**: a user-configured Shortcuts personal automation ("When I get a message") hands text to the app via a custom URL scheme or App Intent the app exposes. No passive/background reading — consistent with the PRD's non-goal and iOS's actual constraints.
- **HealthKit**: standard framework, read-only request for sleep/recovery-adjacent metrics, gated behind the standard iOS permission prompt. No unusual considerations.

## 8. Architecture Risk

The risk isn't any single integration — Calendar, Gmail, HealthKit, and Shortcuts are each individually well-documented and low-risk in isolation. The real risk is **concentration**: five real external integrations, a versioned memory system, and an agentic tool-calling layer, all built in one effort. This needs to be addressed by how the Plan phase breaks the work into independently buildable, independently testable phases — not treated as a single monolithic build. Flagged explicitly for the Plan phase.

## Carried Forward to Decide

Each dimension above has a clear directional recommendation from this discussion. The Decide phase will lock each one formally, along with rejected-alternative rationale, per the user's request to walk through the tradeoffs explicitly at that stage.
