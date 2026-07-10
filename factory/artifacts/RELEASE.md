# Release Notes — Personal Ops Agent v1.0.0

**Status**: Complete
**Last Updated**: 2026-07-10

v1.0.0 is the first complete build: a single-user, native Apple app (iPhone primary, macOS
companion) that acts as a daily operating layer over one person's life — morning briefing, evening
capture, goal tracking, an Ops Inbox, memory Q&A, and voice — all behind a strict "propose, don't
auto-act" safety model. It is **ship-ready for personal use** (Review: ship-ready; Test-QA:
260/260, ready for on-device QA). It "ships" by sideloading to your own devices — see
`DEPLOYMENT.md`.

---

## Changelog — what was built (by phase)

- **Phase 0 — Scaffold & contracts**: SPM-hybrid project (thin Xcode app shell + `PersonalOpsKit`
  package), typed error model, retry policy, source-freshness convention, `RedactingLogger`,
  model-call audit schema, `Config`/`Secrets.example`, and the fixture fakes every later test uses.
- **Phase 1 — Data & memory**: ten SwiftData models with a CloudKit-shaped schema and an
  append-only, revisioned memory system (corrections supersede, never overwrite; conflicts stay
  explicit).
- **Phase 2 — Google Calendar & Gmail**: native PKCE OAuth, Keychain tokens, silent refresh;
  read-only calendar + minimal-scope Gmail; writes confined to an app-owned "Personal Ops Agent"
  calendar with idempotent event IDs.
- **Phase 3A — Goal engine & playbooks**: one shared, data-driven engine with two real playbooks
  (Triathlon Training, Job Search); schedule *previews* only — no calendar writes.
- **Phase 3B — Daily loop UI**: Morning Briefing assembly, Evening Capture, Weekly Review, one-tap
  complete/skip, and a Home/Lock-Screen widget — all deterministic, no LLM.
- **Phase 3C — HealthKit pacing**: read-only sleep/recovery metrics tune goal pacing as a visible,
  toggleable, additive influence; denial leaves everything working.
- **Phase 4A — Proposal system & Ops Inbox**: the safety-critical execution layer — seven typed
  proposal handlers, one action each, executable **only** through user approval (unforgeable
  `ApprovalGrant`); dismissed/snoozed/expired never execute.
- **Phase 4B — Gmail-derived signals**: durable, deduped email→proposal pipeline with mark-as-wrong
  downranking.
- **Phase 4C — Conflict detection & Shortcuts intake**: cross-goal conflict detection by task
  flexibility/policy; iMessage text ingestion via a user-configured Shortcuts automation, always
  as a pending proposal.
- **Phase 5 — LLM reasoning & tool-calling**: Gemini Flash behind a swappable `ReasoningProvider`;
  grounded briefing/review narration and a bounded free-form Q&A loop with a read/propose tool split
  (propose tools can only enqueue a pending proposal).
- **Phase 6 — Voice**: on-device Apple Speech STT + ElevenLabs TTS (system-voice fallback);
  interruptible playback, low-confidence confirmation, voice-first evening capture; transcripts
  never persisted unless confirmed.
- **Phase 7A — CloudKit sync hardening**: sync enabled on the CloudKit-shaped schema with tested
  conflict/merge/migration/dedupe semantics and graceful local-only fallback; opt-in via a config
  flag, off by default.
- **Phase 7B — macOS app target**: a native Mac app sharing the entire UI and logic; HealthKit
  consumed as synced data, per-device Google OAuth, cross-platform voice with a macOS mic path.
- **Post-review remediation** (commit `6a0ed41`): cleared both v1 blockers — a headless Mac build
  (ad-hoc Debug signing) and wiring the four deterministic proposal sources (goal-plan schedule,
  Weekly-Review batch, cross-goal conflicts, Gmail scan) to reachable UI actions — plus three minor
  fixes. Safety-rule tests pass unchanged.

---

## Known limitations & deferred items (v1)

Honest scope shortfalls. None blocks the core loop; each is a deliberate v1 boundary, not a
regression. The first three are host-buildable gaps flagged in `TEST_REPORT.md` §4; the rest are
platform/design boundaries from `IMPLEMENTATION_LOG.md`.

- **Weekly Review is user-triggered, not auto-scheduled.** `ReviewCadence` exists as playbook data
  but isn't wired to a scheduler — you open Review yourself rather than being prompted on the
  configured day.
- **No notification layer.** Morning/evening prompts, Ops Inbox alerts, weekly-review reminders,
  slipped-goal nudges, quiet hours, and per-category mute are unimplemented (PRD Non-Functional; no
  phase scoped it).
- **No data export/delete.** Explicit export and erase of memory (with revision history),
  proposals, logs, and source references is not yet built (PRD Non-Functional).
- **iMessage capture is best-effort, iPhone-only.** iOS forbids background message reading; the
  Shortcuts automation only catches what it's configured to, and attachments/tapbacks/edited/deleted
  messages aren't handled.
- **No Mac iMessage/Shortcuts wrapper.** macOS has no equivalent "When I get a message" automation;
  the platform-neutral core is ready but a Mac entry wrapper is documented as future work.
- **No macOS widget.** The Briefing widget is iPhone/Lock-Screen only; a Mac widget is a separate
  extension, deferred.
- **Google OAuth is per-device.** Each device does its own one-time Google consent (smaller blast
  radius, simpler); single-consent-across-devices via iCloud Keychain is a documented future option.

---

## Device / account-gated verification checklist

Everything below is genuinely correct in code and proven host-side (fixtures, mocks, migration
harness), but can only be **confirmed** on real devices / live accounts. Consolidated from
`IMPLEMENTATION_LOG.md`'s "Consolidated Remaining-Verification Checklist." This is the user's
on-device pass, not outstanding development work.

**Paid Apple Developer Program gate (blocks all cross-device sync):**
- [ ] Enroll in the paid program ($99/yr) — free sideloading and CloudKit are mutually exclusive.
- [ ] Activate CloudKit entitlements (iOS + Mac), create the `iCloud.com.rajatarora.PersonalOpsAgent`
      container, set `CLOUDKIT_SYNC_ENABLED=true` (`docs/CLOUDKIT_SETUP.md`).
- [ ] `NSPersistentCloudKitContainer` constructs on an entitled build (SwiftData's full CloudKit
      validation + record-type provisioning).
- [ ] Two-device sync matrix, rows 1–6 (create/approve, resolve, offline+reconnect, concurrent-approval
      dedupe, conflict surfacing, deletion-vs-edit) + Mac rows 7–11 (`docs/CLOUDKIT_SETUP.md`).
- [ ] Real sync convergence latency within a usable window.

**Per-feature live-credential / device gates (independent of the paid gate):**
- [ ] Google OAuth (iPhone + Mac, per-device): real consent window, real events in-app, agent-calendar
      creation, Keychain persistence on a signed build (`docs/GOOGLE_SETUP.md`).
- [ ] HealthKit (iPhone): real permission sheet, denial leaving reads empty, real sleep/RHR/HRV flowing
      (needs the HealthKit entitlement + usage string on a device build).
- [ ] iMessage/Shortcuts (iPhone): the automation firing, the "Send a message to Personal Ops" action
      appearing, the App Intent writing to the shared store (`docs/SHORTCUTS_SETUP.md`).
- [ ] Gemini: live grounding / honest-ignorance / tool-discipline / propose-containment behavior, real
      function-calling round-trips, latency/429 (needs `GEMINI_API_KEY`).
- [ ] Voice (iPhone + Mac): real mic capture, Apple Speech quality + 0.6-confidence calibration, real
      ElevenLabs playback, audio-session/interruption latency, permission sheets.

**Mac-specific (needs a signed Mac run):**
- [ ] Direct build & run of `PersonalOpsAgentMac` with your Apple ID selected (`docs/MAC_SETUP.md`).
- [ ] macOS microphone + speech-recognition prompts appear and grant/deny correctly.
- [ ] With sync on: HealthKit-influenced pacing appears on the Mac from the iPhone's synced summaries.

**Subjective / real-use (only living with the app confirms):** whether voice "feels good to talk
to," evening-capture adherence, whether the briefing feels trustworthy, and whether live Gemini
stays grounded.

---

## Release checklist — git clone to daily use

The ordered path a user follows. Each item points into `DEPLOYMENT.md` (which in turn references the
`docs/` guides); this is the summary, that is the detail.

1. **Prerequisites** — Mac with Xcode 26.2, an iPhone on iOS 18.0+, a free Apple ID in Xcode, a
   cable. (`DEPLOYMENT.md` → Prerequisites)
2. **Prove the build** — `swift test` and `xcodebuild test` both pass on a clean checkout.
   (`docs/SETUP.md`)
3. **Install on the iPhone** — set your Team, Run from Xcode, trust the developer on-device; know
   the free-tier 7-day re-sign (weekly Cmd-R). (`DEPLOYMENT.md` → Installing on your iPhone)
4. **Run local-first** — exercise the full core loop with no credentials. (`DEPLOYMENT.md` →
   Activation order, step 1)
5. **Add Google** — create your OAuth client, fill `Config.local`, Connect. (`docs/GOOGLE_SETUP.md`)
6. **Add Gemini** — `GEMINI_API_KEY` for the Ask tab + narration. (`ENV_SETUP.md`)
7. **Add ElevenLabs** — `ELEVENLABS_API_KEY` for the high-quality voice (optional).
   (`ENV_SETUP.md`)
8. **Set up Shortcuts** — the iMessage-forwarding automation (iPhone). (`docs/SHORTCUTS_SETUP.md`)
9. **Grant HealthKit** — on the device, for goal pacing (iPhone; optional).
10. **(Optional) Run the Mac app** — build & run `PersonalOpsAgentMac`; connect Google separately.
    (`docs/MAC_SETUP.md`)
11. **(Optional) Enable sync last** — paid account + CloudKit for iPhone↔Mac mirroring, then run the
    two-device matrix. (`docs/CLOUDKIT_SETUP.md`)
12. **Validate** — run the 18-step on-device QA script in `TEST_REPORT.md` §5.

At that point the app is installed, configured to whatever depth you chose, and validated on your
own hardware. Daily use is: Morning Briefing → one-tap through the day → Evening Capture → weekly,
plan next week from the Weekly Review — approving proposals in the Ops Inbox as they arrive.
