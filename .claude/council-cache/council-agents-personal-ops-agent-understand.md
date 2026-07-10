# Council Query — Personal Ops Agent Scope/Feasibility (Understand phase)

Mode: agent-enhanced, single provider (codex only configured)
Verbosity: standard

## 🔳 codex — Agent Analysis

**Quality**: good | **Confidence**: high | **Retried**: no

### Key Recommendations
1. Narrow v1 to the core loop only: morning briefing + evening capture + calendar read/write + a small set of concrete goal templates (triathlon, job search) + basic typed memory; defer Gmail ingestion, iMessage awareness, full voice UI, and capacity/sleep signals to v1.5+
2. Write proposed calendar changes to a dedicated "agent-owned" calendar (using calendar.app.created or calendar.events.owned scope) rather than writing across the user's real calendars, to bound blast radius of bugs
3. Build an "Ops Inbox" as the operational form of "propose, don't auto-act" — a queue of proposals (approve/dismiss/schedule/remember/snooze) rather than a vague policy, since this is the single highest-leverage feature comparable products (Reclaim, Motion, Akiflow) converge on
4. Design memory as explicit typed entities (DailyLog, Commitment, Goal, GoalProgress, Decision, Preference, OpenLoop, Pattern, Proposal) with confidence, source trace, expiration, and correction support — not a growing pile of daily summaries, to avoid hallucinated continuity
5. Treat Gmail and iMessage as adapters, not core dependencies: Gmail body ingestion needs restricted OAuth scopes and should start metadata-only/manual; iMessage access is fundamentally limited by iOS sandboxing and should only come in via user-triggered Shortcuts, never assumed as reliable background ingestion

### Unique Perspective
Grounded its risk assessment in concrete platform documentation (Google Calendar event-ID idempotency and scope tiers, Gmail restricted-scope/security-assessment requirements, Apple Shortcuts personal-automation constraints) rather than generic advice, and proposed specific data-model schemas (Goal/GoalTask, Proposal state machine) that translate the "propose don't auto-act" principle into an implementable state machine instead of leaving it as a design philosophy.

### Blind Spots
Assumes Google Workspace APIs and iOS Shortcuts are the only integration paths and doesn't address what happens if the user's actual Gmail/Calendar accounts have complex sharing setups (work vs personal calendars) or if Claude Fable's iOS build constraints diverge from a generic native-iOS assumption. Also doesn't weigh in on the runtime reasoning model cost/latency tradeoff explicitly deferred to Presearch, nor does it address how much day-to-day burden "evening capture" itself imposes on user adherence — a UX/behavioral risk (will the user actually do evening capture every night) that's arguably as large as the technical risks it flags.

### Full Response

Council Takeaway: the project idea is strong, but the first real version should be narrower than the current capability list.

The winning v1 is not "personal AI chief of staff." It is: A private iOS daily operating app that reads the calendar, tracks a small set of explicit goals, captures what really happened, and produces a trustworthy morning/evening loop with proposed schedule changes. That is already valuable and hard enough.

**1. V1 Scope: Keep vs Cut**

Keep for v1:
- Morning briefing: today's calendar, active goals, yesterday's captured reality, slipping items, one priority
- Evening capture: what happened, what changed, what should tomorrow know
- Google Calendar read/write: create proposed time blocks, update/reschedule only after approval, use stable event IDs to avoid duplicate calendar writes (Google Calendar supports caller-provided event IDs for idempotency and sync reliability)
- Generalized goal system, but only for 2-3 goal templates initially: triathlon training, job search, general recurring commitment
- Basic memory: daily log, goal state, decisions, open loops, user preferences
- Weekly review: keep in v1, but simple — "what changed, what slipped, what matters next week," not a rich analytics dashboard yet

Cut or defer:
- Gmail awareness: defer to v1.5 unless strictly read-only and manually invoked
- iMessage/text-message awareness: defer, treat as experimental until proven with Shortcuts
- Full custom voice interface: defer polished real-time voice; use text-first plus dictation or simple push-to-talk capture first
- Future capacity awareness from sleep/fatigue: defer unless reliable Health data access exists and is explicitly wanted
- Free-form Q&A over all memory: defer broad Q&A, keep narrow queries like "what did I decide about X?" if memory is structured
- Autonomous schedule optimization: do not start here; use proposed changes and explicit approval

The risk: Gmail + Messages + voice + goals + memory + calendar writes creates five hard systems at once. The core daily loop is the product. Everything else should prove it improves that loop.

**2. Biggest Technical / Feasibility Risks**

Messages/iMessage access is the highest platform risk — iOS apps are sandboxed and cannot freely read other apps' private data. Apple's Shortcuts personal automations are user-configured, device-specific, tied to one device. Practical implication: do not make message awareness core to v1; treat it as an ingestion adapter.

Gmail access is feasible but policy-heavy — reading message bodies requires restricted scopes such as gmail.readonly; restricted data stored/transmitted on servers may require a security assessment. Safer first step: manually shared email snippets, search links, or metadata-only experiments.

Calendar writes are feasible but need discipline — use calendar.events.owned or calendar.app.created scope with a dedicated "Personal Ops Agent" calendar instead of writing across all calendars; keep external events read-only.

Voice is a product risk, not just technical — mediocre voice weakens trust. Use app-native text/chat plus iOS dictation or push-to-talk for v1; make "voice-native" a later milestone.

Memory architecture is the real long-term risk — needs explicit types (DailyLog, Commitment, Goal, GoalProgress, Decision, Preference, OpenLoop, Pattern, Proposal) or the agent will hallucinate continuity.

**3. Highest-Leverage Missing Feature**

Not another integration — a trusted inbox for commitments and proposed changes ("Ops Inbox"). Comparable tools (Reclaim, Motion, Akiflow) converge on this pattern: a place where "stuff that might matter" becomes reviewed/accepted/scheduled/dismissed/remembered. Actions: approve, dismiss, schedule, remember, snooze, mark as wrong. This makes "propose, don't auto-act" operational instead of philosophical.

**4. Architectural Red Flags**

1. "Generalized goal system" can become too abstract too early — start with a shared schema (Goal, GoalTask) but implement concrete goal types first, specialize via playbooks later.
2. "Propose, don't auto-act" needs explicit approval states — a durable Proposal object (source, proposedAction, rationale, confidence, affectedObjects, status: pending/approved/rejected/expired/superseded, createdAt, resolvedAt).
3. Growing memory needs garbage collection and correction — support user correction, expiration, confidence, source trace, last confirmed date, promotion from observation to pattern.
4. Calendar should not be the source of all truth — goals/commitments need their own database, or reschedules/deletions/external edits will corrupt the agent's understanding.
5. Single-user personal use still needs privacy architecture — local-first storage where practical, encrypted cloud sync only if needed, explicit export/delete, source-level permissions, no hidden background actions.

**Recommended Problem Summary Adjustment**

"The Personal Ops Agent helps one person convert daily intent into reality by combining calendar context, explicit goals, and evening truth-capture into a trusted daily planning loop. It does not try to fully automate life; it proposes priorities and schedule changes, captures what actually happened, and builds enough structured memory to make tomorrow's briefing more accurate than today's."

Recommended v1 non-goals: no autonomous email/text sending, no unrestricted message reading, no financial/account data, no multi-user or sharing, no broad email ingestion until Gmail access/policy is validated, no full voice-native assistant until the text loop works, no generalized automation without user approval.

---

## Synthesis (single-provider run)

No cross-provider consensus/divergence available — only codex was configured. Assessment of the response itself:

**Adopt as-is:**
- v1 scope cut (core loop first; Gmail/iMessage/full voice/capacity-awareness deferred to v1.5+)
- Ops Inbox concept — turns "propose, don't auto-act" into a concrete feature with a state machine
- Typed memory over free-text summaries — de-risks hallucinated continuity
- Dedicated agent-owned calendar — cheap, meaningfully reduces blast radius

**Adjustment**: keep lightweight voice *capture* (dictation-based, not full conversational voice) in v1 rather than deferring voice entirely — user was clear voice matters to how they want to interact with this day to day.

**Open question carried forward**: evening-capture adherence is a real UX risk (will the user actually do it every night), not just a technical one. Design the evening capture flow to be fast (voice/one-tap) to survive a tired Tuesday.
