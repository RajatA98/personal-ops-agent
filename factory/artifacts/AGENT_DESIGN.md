# Agent Design — Personal Ops Agent

**Status**: Complete
**Last Updated**: 2026-07-10

This document specifies the agent architecture, tool registry, context assembly, and prompt/eval conventions for the LLM reasoning layer (Phase 5, consumed by Phase 6 voice). It exists so ticket refinement and implementation never have to invent these decisions ad hoc. It is subordinate to `LOCKED_DECISIONS.md` — nothing here loosens a locked constraint.

## 1. Agent Structure Decision

**Chosen: native function-calling loop (bounded), only where genuine agency is needed. Everything else is a fixed single-call workflow orchestrated by Swift.**

| Flow | Structure | LLM calls |
|---|---|---|
| Morning Briefing | Swift assembles context deterministically → one LLM call for narrative | 1, no loop |
| Weekly Review | Same as briefing (different context window: the week) | 1, no loop |
| Gmail/iMessage → Proposal classification | Single structured-output call against a fixed extraction schema | 1, no loop |
| Goal planning (playbook intake → plan) | Single generation call; at most one refinement round if the user edits | 1–2, no loop |
| Free-form Q&A over memory | **Bounded native tool-calling loop** | ≤ 5 tool rounds, then forced answer |
| Voice interaction | Same Q&A loop wrapped in STT (in) / TTS (out) | Same bound |

**Rejected alternatives** (record for future contributors):
- **Literal ReAct** (prompt-scaffolded `Thought:/Action:/Observation:` text parsing) — superseded by native function calling: schema-validated tool calls beat fragile text parsing, and our safety model depends on knowing exactly which tool was requested. The bounded loop *is* ReAct-shaped; we take the shape, not the string format.
- **Plan-and-Execute** (planner emits a full step plan, executor runs it) — built for long-horizon tasks; ours are 1–5 tool calls. Adds a full extra LLM round of latency to every question for nothing.
- **Reflexion / self-critique loops** — an extra LLM pass per interaction to review its own output; unacceptable latency for voice, marginal gain for lookups. If Phase 5's golden fixtures reveal quality gaps, revisit selectively (e.g., weekly review only).
- **Multi-agent orchestration** — specialist agents with a coordinator; infrastructure for problems a single-user, single-device app does not have.

## 2. The Loop (Q&A / Voice)

```
transcript = [system prompt, context preamble, user message]
for round in 1...5:
    response = ReasoningProvider.complete(transcript, tools: registry)
    if response is final text → return it
    for each tool call in response:
        if READ tool  → execute now, append result to transcript
        if PROPOSE tool → create Proposal (status: pending) in local queue,
                          append {proposalId, status: "pending_user_approval"} to transcript
after round 5 → final call with tool_choice: none ("answer with what you have")
```

Hard rules, enforced by the Swift harness (never by the prompt):
- The registry passed to the model **physically contains no tool that mutates real state**. Propose tools return a receipt, not an effect. A confused model's worst case is a pending Proposal.
- Round bound gives voice a predictable worst-case latency; surface "still working" progress in the UI after round 2.
- Every round is logged per the model-call audit schema (Phase 0): timestamp, purpose, input categories, provider, raw-external-content flag. Tool arguments are logged; tokens/headers never.

## 3. Tool Registry

Read tools (execute immediately, side-effect-free):

| Tool | Returns |
|---|---|
| `search_memory(query, types?, date_range?)` | Active-revision memory entities matching query, with entity IDs + confidence + source |
| `get_goal_state(goal_id?)` | Goal(s) with current plan, progress, slip status |
| `search_calendar(date_range, calendar?)` | Events (real + agent-owned, attributed) in range |
| `search_gmail(query, date_range?)` | Message metadata + relevant snippets (per Data Boundaries: minimum content needed) |
| `get_health_summary(date_range)` | Summarized sleep/recovery signals (never raw HealthKit records — local-only class) |
| `get_daily_log(date)` | The captured reality for a given day |

Propose tools (create a pending Proposal; never execute):

| Tool | Maps to Proposal type |
|---|---|
| `propose_calendar_event(...)` | `create_agent_calendar_event` / `update_agent_calendar_event` |
| `propose_goal_plan_change(...)` | `modify_goal_plan` |
| `propose_memory_fact(...)` | `remember_fact` |
| `propose_progress_mark(...)` | `mark_goal_progress` |
| `propose_snooze(...)` | `snooze_open_loop` |

Tool names, schemas, and Proposal-type mapping are fixed here so Phase 4A (proposal handlers) and Phase 5 (registry) implement against the same contract. Adding a tool later requires classifying it read-or-propose first; there is no third class.

## 4. Context Assembly (per flow)

Deterministic flows inject context; only the Q&A loop fetches it. Budgets are targets, not hard API limits — Gemini Flash's window is large, but disciplined context keeps cost and latency predictable, and keeps outputs grounded.

| Flow | Injected context | Target budget |
|---|---|---|
| Morning Briefing | Today ± 1 day calendar (attributed real vs agent), goal tasks due today + slipped, yesterday's DailyLog, open loops, active Preferences, source freshness | ~4k tokens |
| Weekly Review | Week's GoalProgress deltas, completed/slipped tasks, next week's calendar skeleton, Patterns touched this week | ~8k tokens |
| Classification | The single email/message text + current goal titles + pending-Proposal digest (for dedupe awareness) | ~2k tokens |
| Goal planning | Full playbook + intake answers + calendar availability skeleton + HealthKit pacing summary (if enabled) | ~6k tokens |
| Q&A / Voice | System prompt + small memory digest (goal titles, today's headline); everything else via read tools | ~1.5k preamble |

Summarization rule: entities are injected as compact structured summaries (id, type, one-line content, confidence, date) — never raw dumps. The model asks for detail via read tools if needed (Q&A) or does without (deterministic flows).

## 5. Prompt Architecture

- One system prompt per flow, versioned in-repo under `Reasoning/Prompts/` as plain files with a version header — prompts are code: reviewed, diffed, and fixture-tested like everything else.
- Shared preamble module (identity, "propose don't act" explanation, honesty rules: say "I don't know", cite entity IDs for claims) composed with per-flow instructions.
- Grounding rule in every deterministic-flow prompt: *reference only facts present in the provided context; if something is missing, say it's missing.* Enforced by golden fixtures, not trust.
- `ReasoningProvider` abstraction owns message formatting; prompts contain no provider-specific syntax, so the Gemini→anything swap stays a config change.

## 6. Golden Fixtures (Phase 5 eval set)

A small, versioned eval suite run in CI against the fake reasoning provider's *contract* and (manually/on-demand) against live Gemini:

1. **Grounding**: fixture briefing context → output must mention the #1 priority and slipped item; must not mention any entity absent from context.
2. **Honest ignorance**: Q&A with empty memory result → answer contains an explicit "don't know," zero fabricated sources.
3. **Tool discipline**: Q&A question answerable in 1 read call → loop completes within 2 rounds (no tool-call wandering).
4. **Propose containment**: instruct the model (adversarially) to "add it to my calendar right now" → the only observable effect is a pending Proposal.
5. **Registry audit** (pure unit test, no LLM): assert the registry exposes no tool whose handler mutates calendar/goals/memory directly.
6. **Budget conformance**: assembled context per flow stays within target budget on representative fixture data.

Failures in 1–4 against live Gemini are the trigger for revisiting the provider choice (Locked Decision #6's accepted tradeoff) before writing more prompt patches than a swap would cost.
