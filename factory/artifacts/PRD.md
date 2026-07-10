# Product Requirements Document — Personal Ops Agent

**Status**: Complete
**Last Updated**: 2026-07-10

## Overview

Personal Ops Agent is a native iOS application, built for a single user, that acts as a daily operating layer over their real life. It runs a morning-briefing / evening-capture rhythm on top of Google Calendar, Gmail, iMessage (via Shortcuts), and HealthKit, backed by a generalized goal-tracking engine and structured, correctable memory. It has a real conversational voice interface and proposes — never silently executes — any action that touches the user's calendar, goals, or external accounts.

See `factory/artifacts/PROBLEM_SUMMARY.md` for the full problem framing, design principles, and the record of the scope discussion (including council review and the user's decision to keep v1 ambitious).

## Goals

1. Give the user a trustworthy morning briefing — grounded in what's actually on the calendar, what's actually true about their goals, and what actually happened yesterday — not a static plan.
2. Give the user a fast, low-friction way to capture what happened each evening, so tomorrow's briefing stays accurate.
3. Let the user define and track goals (starting with Triathlon Training and Job Search) with a plan, a schedule, and real accountability.
4. Surface anything ambiguous or externally sourced (an email, a text, a scheduling conflict) through a single review queue (Ops Inbox) rather than acting on it silently.
5. Provide a real voice interface for interacting with the agent, not a Siri-relay command dispatcher.
6. Never take an irreversible or externally-visible action (sending a message, creating a calendar event on a real calendar, modifying a goal plan) without the user's approval.

## Users

Single user: the app's owner. No other user roles, no multi-tenancy, no sharing or collaboration surface, ever.

## Core Flows

### 1. Morning Briefing
User opens the app (or asks via voice) in the morning. The agent assembles: today's calendar (real + agent-owned), active goals and their current state, yesterday's captured reality, anything slipping, and one recommended priority. Delivered as text and/or voice.

### 2. Evening Capture
User is prompted (or initiates) an evening capture — fast, voice-first or one-tap, not a form. The agent extracts what happened, updates DailyLog/GoalProgress/OpenLoop memory entities, and reconciles against what was planned for the day.

### 3. Goal Creation & Planning
User creates a goal (e.g., "train for Ironman 70.3 in October" or "land a PM role by Q4"). The agent asks clarifying questions, proposes a plan and a schedule, and — on approval — writes the schedule as proposed events to the agent-owned calendar.

### 4. Ops Inbox Review
Anything the agent finds that might need action — a plan-like email, a plan-like text (surfaced via a Shortcuts automation), a slipping goal, a calendar conflict between two goals — becomes a Proposal in the Ops Inbox. User approves, dismisses, schedules, remembers, or snoozes each one. Nothing here writes to the real calendar or sends anything without this explicit step.

### 5. Voice Interaction
User speaks to the agent (in-app, not via Siri). Speech is transcribed on-device, sent to the reasoning model with relevant memory/context, and the response is spoken back. Supports both structured queries ("what's today") and open-ended ones ("what did I decide about the Acme offer last week").

### 6. Weekly Review
On a set day (default: Sunday evening, user-configurable), the agent generates a rollup: what changed, what slipped, what's next week's priority per goal.

### 7. Conflict Detection
Whenever a new proposed event or plan would collide with another goal's time (e.g., a training block and a job-search prep block), the agent surfaces the conflict as a Proposal instead of silently double-booking.

## Acceptance Criteria (per core flow)

- **Morning Briefing**: shows today's real calendar events and agent-owned events separately; shows active goal commitments due today; identifies at least one slipped item when yesterday's planned task lacks completion evidence; displays source freshness (calendar/Gmail/HealthKit last-synced times); can be generated even when Gmail/HealthKit permissions are absent, clearly noting what's missing rather than implying completeness.
- **Evening Capture**: completes in under one voice/tap interaction for the common case; reconciles captured reality against the day's plan; updates DailyLog/GoalProgress/OpenLoop without requiring a form.
- **Goal Planning**: produces a schedule proposal the user can approve/edit/reject as a whole before any calendar write occurs; a rejected plan does not silently retry.
- **Ops Inbox**: every Proposal is actionable (approve/dismiss/schedule/remember/snooze/mark-as-wrong); approving a Proposal executes only the action described in it, never an inferred follow-up action.
- **Voice**: user can interrupt playback; low-confidence transcriptions require confirmation before creating a Proposal or memory entry.
- **Weekly Review**: generated on the configured day even if some data sources were degraded that week, with degraded sources explicitly noted.
- **Conflict Detection**: flags true time overlaps between fixed-flexibility tasks at minimum; movable/optional tasks are flagged per their configured conflict policy (block/warn/allow), not always hard-blocked.

## Functional Requirements

**Calendar**
- Read events from the user's real Google Calendar(s).
- Create/update/delete events only on a dedicated agent-owned calendar, using idempotent (caller-provided) event IDs.
- Never write directly to the user's personal/primary calendar without an explicit approved Proposal.
- Retry calendar writes safely (idempotent) rather than duplicating events on transient failure.

**Goals**
- Generalized goal schema (`Goal`, `GoalTask`) supporting multiple goal types via domain-specific playbooks, not hardcoded to Training/Job Search.
- A **goal playbook** defines: intake questions, milestone schema, task-generation rules, progress signals, review cadence, slip-detection rules, schedule-block templates, and completion criteria. Training and Job Search ship as the first two playbooks; new goal types are added as new playbooks, not new code paths.
- Each `GoalTask` schedule block carries: flexibility (`fixed` | `movable` | `optional`), priority, earliest/latest acceptable time, expected duration, and a conflict policy (`block` | `warn` | `allow`).
- Support creating, editing, pausing, and completing goals.
- Track goal progress over time (`GoalProgress`) and generate schedules from a goal's plan.

**Memory**
- Typed entities: `DailyLog`, `Commitment`, `Goal`, `GoalProgress`, `Decision`, `Preference`, `OpenLoop`, `Pattern`, `Proposal`.
- Each entity carries confidence, source, timestamps, and supports user correction and expiration.
- **Memory lifecycle**: the audit layer is append-only. A correction creates a new revision that supersedes the prior value while preserving source, timestamp, and reason — corrections never destructively overwrite history. Queries return the active, non-expired revision by default and surface uncertainty when conflicting memories exist for the same fact.
- Support free-form natural-language queries over memory ("what did I decide about X"), resolved against active revisions.

**Ops Inbox / Proposals**
- Proposal actions are typed, not generic — e.g. `remember_fact`, `create_agent_calendar_event`, `update_agent_calendar_event`, `modify_goal_plan`, `mark_goal_progress`, `snooze_open_loop`, `dismiss_signal`. Each type has its own execution handler and confirmation copy; approving a Proposal executes only that Proposal's described action, never an inferred follow-up.
- Every Proposal has: source, proposed action (typed, as above), rationale, confidence, affected objects, and a status (pending/approved/rejected/expired/superseded).
- User actions on a Proposal: approve, dismiss, schedule, remember, snooze, mark-as-wrong.
- No Proposal auto-resolves to "approved" — expiration means the proposal is dropped, not silently actioned.

**Gmail**
- Read-access integration (personal-use OAuth, single-user client) to surface commitments/events found in email as Proposals.
- Email-derived Proposals include the source message/thread ID; repeated scans of the same thread are deduplicated.
- If the user marks a Gmail-derived Proposal as wrong, similar future extraction from that source pattern is downranked or suppressed.
- No sending of email on the user's behalf.

**iMessage**
- Integration via a user-configured iOS Shortcuts personal automation ("when I get a message") that hands text content to the app for classification into a Proposal.
- No passive/background message reading (not permitted by iOS) — this is best-effort and user-configured, not guaranteed complete coverage.
- Shortcut-provided messages are treated as untrusted external text with explicit source metadata attached (not silently equated with a verified source like Calendar).
- Attachments, reactions, edits, and deleted messages are out of scope for v1 unless the Shortcut payload explicitly captures them.

**HealthKit**
- Read sleep/recovery signals (with explicit user permission) to inform pacing suggestions within goal plans.
- Pacing suggestions influenced by HealthKit data are visibly labeled as such; this is pacing guidance, not medical advice.
- The user can disable HealthKit influence on pacing without disabling goals themselves.

**Voice**
- On-device speech-to-text capture within the app.
- Text-to-speech playback of agent responses; the user can interrupt playback at any time.
- Full conversational turn-taking (not single-command dispatch); the agent can ask clarification questions mid-conversation.
- Voice transcripts are not stored as memory by default — only when they produce an approved or confirmed memory update.
- Low-confidence transcriptions require user confirmation before creating a Proposal or memory entry.

## Data Boundaries & Privacy Classes

Data is classified into three tiers, and every integration/feature must declare which tier its data falls into:

- **Local-only** (never leaves the device without explicit per-task approval): raw HealthKit data, OAuth tokens/credentials, raw iMessage text payloads.
- **Model-eligible** (may be sent to the reasoning model as needed for a task): summarized calendar context, approved memory snippets, user-entered prompts and voice transcripts being actively processed.
- **Never-sent**: credentials, full OAuth tokens, unredacted message/email bodies beyond what's needed for the specific classification task at hand.

Every call to the reasoning model is logged with: timestamp, purpose, input categories (not necessarily raw content), model provider, and whether raw external content was included.

## Integration Failure Modes

The app must degrade visibly, never silently imply completeness it doesn't have:

- The Morning Briefing shows source freshness for each major input (calendar last synced at X, Gmail last scanned at Y, HealthKit last read at Z); if a source is unavailable, the briefing states that rather than omitting it silently.
- Voice interaction failure (model API unavailable): falls back to text, with a visible error state — not a silent hang.
- Calendar write failure: retried idempotently; the user is told if a write could not be completed rather than the Proposal silently disappearing.
- HealthKit permission denied: goals and pacing continue to function without HealthKit influence.
- Malformed or delayed Shortcut payload: dropped with no Proposal created, not guessed at.
- OAuth token revoked or expired: the affected integration degrades gracefully (its data is simply absent from briefings) and creates an Ops Inbox item or settings alert prompting reconnection — it does not fail silently or crash the briefing.

## Non-Functional Considerations

- **Privacy/security**: local-first storage where practical (see Data Boundaries & Privacy Classes above); OAuth scopes requested are the minimum needed per integration; OAuth tokens are stored in iOS Keychain; the app supports disconnecting each integration individually; access/refresh tokens and authorization headers are never logged; no data is used to send communications without approval; explicit data export/delete supported, covering memory (including revision history), proposals, logs, and source references — local-only data included.
- **Reliability**: calendar writes must be idempotent (safe to retry without creating duplicates); memory must support correction via versioned revisions rather than requiring deletion/recreation (see Memory lifecycle above).
- **Cost**: the runtime reasoning model is swappable — architecture must not hard-couple to a single model provider, since the model choice will change post-Fable for cost reasons.
- **Build process**: the app is implemented using Claude Fable as the build/coding tool. This is a build-time constraint only and must not influence runtime architecture decisions (e.g., no assumption that the deployed app runs on or depends on Fable).
- **Platform**: native iOS; iPhone 17 Pro is the primary target device, but Presearch/Plan must also fix a minimum supported iOS version and the hardware capabilities (e.g., on-device speech APIs, HealthKit access) the app actually depends on.
- **Latency**: voice interaction should feel conversational, not batch — acceptable latency bounds to be validated during Presearch/Plan once a voice stack is chosen.
- **Background execution**: Presearch/Plan must fix whether calendar/Gmail sync, HealthKit reads, and Shortcut ingestion are foreground-only, background-best-effort, or notification-driven, given iOS background execution limits.
- **Notifications**: morning/evening prompts, Ops Inbox alerts, weekly review, and slipped-goal nudges require a defined notification policy — frequency, quiet hours, and user-facing controls to adjust or mute each category.
- **Observability**: agent outputs expose their supporting sources where practical (calendar event IDs, Proposal IDs, memory entity IDs, or source summaries) so the user can always ask "why did it say that."

## Non-Goals

- No multi-user, sharing, or collaboration features, ever.
- No autonomous sending of emails or texts on the user's behalf without explicit approval.
- No financial data or financial accounts.
- No passive/background reading of Messages (iOS does not allow this).
- No generalized/autonomous schedule optimization without user approval — the agent proposes, the user decides.

## Open Questions

1. Evening-capture adherence is a UX risk, not a technical one — needs a fast (voice/one-tap) design and real-world validation once built.
2. Exact Gmail OAuth scopes and iMessage Shortcuts automation design — to be finalized in Presearch/Plan.
3. Exact runtime reasoning model and voice stack (on-device vs. cloud STT/TTS) — to be decided in Presearch.
