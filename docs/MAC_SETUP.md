# Mac App — Building, Running, and What Differs from iPhone (Phase 7B)

This is the step-by-step for running the **macOS companion app** (`PersonalOpsAgentMac`) on your
own Mac, plus an honest map of what works the same as iPhone, what works differently, and what is
gated behind the paid Apple account or your real devices.

The Mac app shares the *entire* screen layout and business logic with the iPhone app — same
Briefing, Capture, Review, Inbox, Goals, Ask, Memory, and Integrations tabs, same "propose, don't
auto-act" safety model. It is a second window onto the same data, the way Apple's own Notes and
Reminders show the same content on your iPhone and Mac.

---

## The big picture: the Mac app is only fully useful *with sync*

The whole point of the Mac app is to see and act on the **same data** as your iPhone. That
cross-device sharing is CloudKit sync, and **CloudKit requires a paid Apple Developer Program
membership** (see `docs/CLOUDKIT_SETUP.md` for the full free-vs-paid explanation). So:

- **Without sync (free account):** the Mac app runs perfectly, but it only shows *its own* local
  data on that Mac — it does not see what you did on your iPhone. Useful for trying the app out;
  not the intended daily setup.
- **With sync (paid account):** the Mac and iPhone mirror the same private iCloud database, so a
  proposal you approve on the iPhone shows up resolved on the Mac, and vice versa.

You can build and run the Mac app today either way. Turning on sync is the separate step in
`docs/CLOUDKIT_SETUP.md`.

---

## 1. Build & run the Mac app

Unlike the iPhone side, the Mac has **no sideloading ceremony** — no 7-day resign cycle, no
device provisioning. You just build and run on the same Mac you develop on.

In Xcode:
1. Open `PersonalOpsAgent.xcodeproj`.
2. Choose the **PersonalOpsAgentMac** scheme (next to the Run button).
3. Pick **My Mac** as the run destination.
4. First time only: select the target → **Signing & Capabilities** → set **Team** to your Apple
   ID (a free Apple ID is fine for running locally on your own Mac). Automatic signing handles the
   rest.
5. Press **Run** (Cmd-R). The app launches as a normal Mac window.

Or from the command line (this is the phase's build-verification command):
```bash
xcodebuild build \
  -project PersonalOpsAgent.xcodeproj \
  -scheme PersonalOpsAgentMac \
  -destination 'platform=macOS'
```
(A headless/CI machine without a signing certificate needs `CODE_SIGNING_ALLOWED=NO` added; a real
Mac with your Apple ID selected signs automatically.)

### Secrets
Same as iPhone: real Google/Gemini/ElevenLabs features need `Secrets/Config.local` (copy from
`Secrets/Config.example`). Without it the app still runs — Integrations shows disconnected, Ask
shows "assistant unavailable", voice falls back to the system voice. See `docs/SETUP.md`.

---

## 2. What's the same as iPhone

- **The whole UI and daily loop.** Every tab and flow is the identical shared SwiftUI code.
- **Data model, memory system, proposals, goals.** All shared, all synced (when sync is on).
- **Google Calendar & Gmail.** Same direct REST integration over the network (not the local macOS
  Calendar app). `ASWebAuthenticationSession` — the consent window — works natively on macOS.
- **The LLM reasoning layer (Ask tab).** Same Gemini path; it's just a network call.

---

## 3. What differs on the Mac (by design)

### HealthKit → consumed as *synced data*, never read natively
macOS has no HealthKit framework, so the Mac **cannot** read your sleep/heart-rate data directly.
Instead: your **iPhone** reads HealthKit and mirrors a small per-day *summary* (sleep hours,
resting heart rate, HRV — never raw samples) into a synced record. The Mac reads those synced
summaries and feeds them into the exact same pacing engine. So on the Mac you still see
"HealthKit-influenced" pacing on your goals — it's just powered by data your iPhone measured and
synced, not a Mac sensor.

- This needs sync on (paid account). With sync off, the Mac simply shows *no* pacing influence and
  says so honestly — goals and the daily loop work fully regardless.
- Raw HealthKit samples never leave your iPhone; only the coarsened summary syncs, and only within
  your own private iCloud database.

### Google OAuth → authorize **per device**
You connect Google **once on the Mac too** (a separate one-time consent), exactly as you did on the
iPhone. We deliberately do **not** share the Google tokens across devices via iCloud Keychain.

Why per-device is the default:
- It's simpler and has a smaller blast radius — a token problem on one device never affects the
  other, and disconnecting Google on the Mac doesn't touch the iPhone's connection.
- iCloud Keychain token-sharing would couple the two devices' auth state and add a subtle failure
  mode (a refreshed/revoked token racing between devices) for no real benefit at single-user scale.
- The tradeoff — one extra "Connect Google" click on the Mac — is trivial and one-time.

If you ever want single-consent across devices, that's a documented future option (move the token
store to an iCloud-Keychain-backed access group); it is intentionally not the v1 behavior.

### Voice → works, with a Mac microphone-permission prompt
On-device speech-to-text (Apple Speech) and text-to-speech (ElevenLabs, or the system voice
fallback) are platform-agnostic and work on the Mac's mic/speakers. The first time you use voice,
macOS shows its **microphone** and **speech recognition** permission prompts (the app declares the
matching usage strings). The Mac app requests microphone access through the macOS capture-device
API (there is no iOS-style audio session on the Mac; the conversation/turn logic is identical).

### iMessage / Shortcuts intake → **iOS only for now**
On iPhone, a "When I get a message" Shortcuts personal automation can forward a text into the app
as a proposal (see `docs/SHORTCUTS_SETUP.md`). **macOS does not offer that same message-triggered
automation**, so this intake path is iPhone-only in v1.

- The *core* that turns forwarded text into a classified proposal (`ShortcutIntakeService` /
  `PlanTextExtractor`) is platform-neutral shared code — a Mac entry wrapper is straightforward to
  add later, but the macOS Shortcuts automation surface (and its entitlement/invocation path)
  needs to be confirmed on a real Mac before shipping it, so it is **documented as future work**
  rather than half-built.
- Nothing is lost: anything captured on the iPhone this way syncs to the Mac like all other data.

### Widget → **iOS only**
The Briefing widget stays an iPhone/Lock-Screen feature. A macOS widget (Notification Center /
desktop) is a separate build with its own extension and is **future work**, not part of this phase.

---

## 4. What's gated (can't be finished in the build itself)

These need your paid account and/or your real devices — they cannot be verified by building alone:

- **iPhone ↔ Mac sync end-to-end.** Requires enrolling in the paid Apple Developer Program and the
  steps in `docs/CLOUDKIT_SETUP.md`. Until then the Mac shows only its own local data.
- **HealthKit pacing on the Mac.** Depends on sync being on (so the iPhone's summaries reach the
  Mac). With sync off, pacing influence is simply absent on the Mac.
- **The Mac sync test matrix.** The same two-device matrix in `docs/CLOUDKIT_SETUP.md` now extends
  to the Mac — see the "Mac companion" rows there.

---

## 5. One-time capabilities recap (Mac)

The Mac target ships **sandboxed** with a free-tier-safe default entitlements file
(`App/PersonalOpsAgentMac.entitlements`): App Sandbox on, outbound network (for Google/Gemini/
ElevenLabs), microphone (for voice), and the shared app group. A ready-to-activate CloudKit variant
lives in `App/PersonalOpsAgentMac.CloudKit.entitlements` — switch to it (and set
`CLOUDKIT_SYNC_ENABLED=true`) once you're on the paid account, exactly like the iPhone side.
