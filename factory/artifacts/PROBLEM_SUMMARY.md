# Problem Summary — Personal Ops Agent

**Status**: Complete
**Last Updated**: 2026-07-10

## Problem Statement

The user's daily life is split across disconnected surfaces — a calendar, a training plan (triathlon), a job search, and whatever they remember from yesterday — with nothing that ties them together and keeps the plan honest. There is no existing tool or manual system doing this today; this is greenfield.

The Personal Ops Agent helps one person convert daily intent into reality by combining calendar context, explicit goals, and evening truth-capture into a trusted daily planning loop. It does not try to fully automate life; it proposes priorities and schedule changes, captures what actually happened, and builds enough structured memory to make tomorrow's briefing more accurate than today's.

**Core rhythm**:
- **Morning briefing**: today's calendar, active goals, yesterday's captured reality, what's slipping, one priority to focus on.
- **Evening capture**: what actually happened, logged fast enough to survive a tired Tuesday, updating memory so tomorrow's briefing is grounded in reality rather than a stale plan.

## Why Now

This is greenfield — the user isn't currently doing this loop manually in any tool (no Obsidian, no spreadsheet system). They have Claude Fable access via their Claude Max plan right now, which is free/included but expected to become billed usage eventually — this creates real urgency to build the implementation now, while build costs are low, even though the runtime model choice for the deployed agent is a separate, later decision.

## Target User

A single person (the user) — this is a personal application, not a multi-user product. No sharing or collaboration features are planned, ever.

## What It Does (v1 — ambitious scope)

The user has significant build leverage right now (Claude Fable) and wants v1 to be genuinely comprehensive, not a stripped-down MVP. The scope below distinguishes things that are purely a matter of build effort (expanded, since Fable removes that constraint) from things constrained by actual platform policy (kept honest, since no amount of build power changes Apple/Google's rules).

- **Google Calendar — read and write.** The agent proposes and creates events (e.g., turning a goal's plan into scheduled time), written to a **dedicated agent-owned calendar** rather than mixed into the user's real calendars, to bound the blast radius of bugs.
- **Generalized goal engine**, built properly from the start rather than 2-3 hardcoded templates — a real shared schema (Goal, GoalTask, playbooks per domain) so Triathlon Training and Job Search launch as the first two goals, with new goal types addable without re-architecting.
- **Typed memory** — explicit entities (DailyLog, Commitment, Goal, GoalProgress, Decision, Preference, OpenLoop, Pattern), each carrying confidence, source, and the ability to be corrected or expire. Avoids the agent hallucinating continuity it doesn't actually have.
- **Weekly review** — a rollup of what changed, what slipped, and what matters next week, sitting on top of the daily loop.
- **Cross-goal conflict detection** — when two goals compete for the same time (e.g., a long training block and job-search prep), the agent surfaces the conflict instead of silently double-booking or dropping one.
- **Capacity/fatigue awareness** — uses HealthKit signals (sleep, recovery) to pace the plan rather than blindly pushing a fixed schedule. This is a supported, permission-gated Apple API, not a platform restriction — genuinely buildable in v1.
- **Free-form Q&A over memory** — since the memory system is typed and structured, conversational recall ("what did I decide about the Acme offer last week") is a natural feature on top of it, not a separate system.
- **Gmail integration** — reads for commitments/events buried in email. For a personal-use app where the user is the sole OAuth user of their own client, Google's verification/security-assessment burden (which applies to apps serving many external users) does not apply — this is more in-reach than initially assumed, and is included in v1.
- **Ops Inbox** — the concrete, operational form of "propose, don't auto-act": a queue of proposals (a possible commitment found in email/text, a slipping goal, a scheduling conflict) the user can approve, dismiss, schedule, remember, or snooze. This is what makes the "propose, don't auto-act" principle real instead of aspirational.
- **Real conversational voice agent** — a genuine voice interface inside the user's own app (on-device speech-to-text, Claude for reasoning, text-to-speech for the reply), not routed through Siri's rigid App Intents relay. Siri Shortcuts remain a fast-follow convenience layer on top, not a substitute.
- **Text-message (iMessage) awareness** — included in v1, built the only way Apple actually allows: a user-triggered iOS Shortcuts automation hands message text to the app for classification. This is not deferred for lack of ambition — it's a hard platform constraint (no third-party app can passively read Messages, regardless of build capability), so v1 includes it in the form Apple permits rather than skipping it.

## Design Principles

1. **Propose, don't auto-act.** Anything ambiguous or externally sourced (a text, an email, a schedule conflict) is surfaced through the Ops Inbox for approval — never silently written to the calendar or acted on.
2. **Calendar is not the source of truth.** Goals and commitments live in their own data model; the calendar is just the execution surface the agent writes proposed time blocks to.
3. **Memory must be correctable and bounded.** Typed entities with confidence, source trace, and expiration — not an ever-growing pile of daily notes.

## Constraints

- **Platform**: iPhone 17 Pro / iOS native.
- **Single user only** — no multi-user or sharing features, ever.
- **Build tool**: Claude Fable, used to implement the app while it's free under the user's Claude Max plan. This is a build-time tool choice, separate from the runtime reasoning model.
- **Runtime reasoning model**: a separate, cost-sensitive decision, deferred to Presearch — likely a cheaper model, possibly non-Claude, since long-term operating cost matters.
- **Data sources for v1**: Google Calendar (read/write), Gmail, iMessage (via Shortcuts), and HealthKit (sleep/recovery).

## Non-Goals

- No multi-user, sharing, or collaboration features — ever.
- No autonomous sending of emails or texts on the user's behalf, without explicit approval.
- No financial data or financial accounts — out of scope entirely for now.
- No unrestricted/passive background reading of Messages (Apple does not permit this regardless of build effort — iMessage awareness works only via user-triggered Shortcuts).
- No generalized/autonomous schedule optimization — the agent proposes, the user approves, always.

## Deferred (genuine convenience layer, not core)

- **Siri Shortcuts fast-follow** — quick one-liner voice commands ("Hey Siri, log my run") routed into the app. Additive on top of the real in-app voice agent, not required for v1 to be complete.

## Open Questions

1. **Evening-capture adherence** is a real UX risk, not just a technical one — the whole system's value depends on the user actually doing a nightly capture. This needs to be designed to be fast (voice/one-tap) rather than a form, and should be validated once built rather than assumed.
2. Exact Gmail/iMessage integration mechanics (OAuth scope requests, Shortcuts automation design) are a Presearch/Plan-level detail, not resolved here.
3. Exact runtime reasoning model and voice stack (on-device vs. cloud STT/TTS choice) are deferred to Presearch — this is a cost/latency/quality tradeoff independent of Fable, which is a build-time tool only.

## Input From Council Review

Before finalizing this summary, an independent AI council review (codex, agent-enhanced) was run to pressure-test scope and flag feasibility risks. It recommended narrowing v1 to a minimal core loop and deferring Gmail, iMessage, full voice, and capacity-awareness to v1.5+.

The user pushed back on this: the council's caution conflated two different things — genuine platform policy constraints (iOS sandboxing blocks passive Messages reading, full stop) and pure build-effort tradeoffs (the council assumed a small, staged team; the user has Claude Fable, a materially higher build-capability tool, and wants v1 to be comprehensive, not minimal). On review, this distinction holds up: Fable changes how much can be built well in one pass, not what Apple or Google's platform policies allow. Gmail was also re-assessed — personal-use OAuth (a single user on their own client) does not trigger Google's verification/security-assessment burden, which only applies to apps serving many external users, so Gmail is more in-reach than the council assumed.

**Final scope decision**: v1 is ambitious — it includes Gmail, iMessage (via Shortcuts, the only mechanism Apple allows), a real conversational voice agent, the full generalized goal engine, pattern memory, weekly review, cross-goal conflict detection, capacity/fatigue awareness (HealthKit), and free-form Q&A over memory. The council's architectural contributions were kept as-is, because they're correct engineering regardless of ambition level: the Ops Inbox as the operationalization of "propose, don't auto-act," typed memory over free-text summaries, and a dedicated agent-owned calendar to bound blast radius. Full council analysis saved at `.claude/council-cache/council-agents-personal-ops-agent-understand.md`.
