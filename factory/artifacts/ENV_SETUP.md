# Environment & Credentials Setup — Personal Ops Agent

**Status**: Complete
**Last Updated**: 2026-07-10

Every credential and setting the app needs, in one place, in plain language. This is the
"what do I have to sign up for, what does it cost, and what happens if I skip it" reference.
It does **not** replace the step-by-step guides — it points to them. For the actual clicks,
follow the linked `docs/` files.

The whole app is designed so **nothing here is mandatory to launch**. Missing a credential
never crashes the app — the feature that needs it simply switches off and says so. You can
add credentials one at a time and watch features light up (see `DEPLOYMENT.md` for the
recommended order).

---

## Where the settings live

All four settings go in a single file: **`Secrets/Config.local`**. You create it once by
copying the tracked template:

```bash
cp Secrets/Config.example Secrets/Config.local
# then edit Secrets/Config.local and fill in real values
```

Format is `KEY=VALUE`, one per line. The template (`Secrets/Config.example`) is the source of
truth for the exact key names. `Config.local` itself is **gitignored** — it never enters the
repository (see "How your secrets are protected" below).

> For a build running **on a device** (not the simulator), `Config.local` must be included in
> the app bundle so the app can read it at launch. In Xcode, drag `Secrets/Config.local` into
> the project and tick it for the target under **Target Membership** (and for the Mac target if
> you build that too). If the app can't find the file it simply starts **unconfigured** — it
> won't crash.

---

## The four settings

| Setting | Feature it powers | Cost | If you skip it |
|---|---|---|---|
| `GOOGLE_OAUTH_CLIENT_ID` | Read your real Google Calendar + Gmail | **Free** | Calendar/Gmail show "Not connected"; briefing has no real events; no email-derived proposals |
| `GEMINI_API_KEY` | The "Ask" assistant + narrative polish on briefings | **Free tier + pay-as-you-go** | "Ask" tab shows "Assistant unavailable"; briefings/reviews use plain deterministic text (no LLM narration) |
| `ELEVENLABS_API_KEY` | High-quality spoken voice (text-to-speech) | **Free tier (limited) + paid tiers** | Voice still works, using Apple's built-in system voice instead (more synthetic) |
| `CLOUDKIT_SYNC_ENABLED` | iPhone ↔ Mac data sync | **Requires paid Apple Developer Program ($99/yr)** | Each device works fully on its own, local-only; they just don't share data |

Every feature above **degrades gracefully** — the rest of the app keeps working. The core loop
(goals, proposals, Ops Inbox, morning briefing assembly, evening capture, memory) runs with
**zero** credentials configured.

---

### 1. `GOOGLE_OAUTH_CLIENT_ID` — Google Calendar & Gmail

- **What it is**: an ID card for an "app" you register in your own free Google Cloud project, so
  Google will let this app read *your* Calendar and Gmail (and only yours).
- **Where to get it**: `docs/GOOGLE_SETUP.md` — a ~15-minute, no-prior-experience walkthrough
  (create a Google Cloud project → enable Calendar + Gmail APIs → make an iOS OAuth client →
  list yourself as a test user → copy the Client ID). There is **no client secret** for an iOS
  client; the app proves its identity with PKCE instead.
- **Cost**: **completely free.** Everything uses Google's free tier. You keep the project in
  "Testing" publishing status (no verification, no review) because only you use it.
- **Permissions requested** (deliberately the narrowest possible): `calendar.readonly` (read your
  real calendars, can never change them), `calendar.app.created` (create/write events **only** on
  the app's own "Personal Ops Agent" calendar — makes writing to your real calendars structurally
  impossible), and `gmail.readonly` (read/search email to spot plan-like messages; there is **no**
  send permission anywhere). Full rationale table in `docs/GOOGLE_SETUP.md`.
- **Without it**: the Integrations tab still opens, Calendar/Gmail read "Not connected," and
  tapping **Connect** shows a clear "Missing configuration" message. The whole rest of the app
  works — you just won't see real calendar events or get email-derived proposals.

### 2. `GEMINI_API_KEY` — the reasoning/assistant layer

- **What it is**: an API key from Google AI Studio for the Gemini model (Flash tier,
  `gemini-2.0-flash`) that powers the free-form **Ask** tab and writes the narrative summaries on
  the Morning Briefing and Weekly Review. Everything Gemini does is behind a swappable provider —
  a different model is a one-line change, not a rewrite.
- **Where to get it**: Google AI Studio (aistudio.google.com) → "Get API key." Paste it into
  `Config.local`.
- **Cost**: Gemini has a **free tier** with daily request/rate limits that is generous enough for
  single-user daily use, plus **pay-as-you-go** pricing beyond it (billed per million tokens).
  Flash is Google's low-cost tier, so even paid usage for one person is small. Exact current rates
  are on Google's pricing page; treat the free tier as "likely enough," with pay-as-you-go as the
  overflow.
- **Safety note on cost**: the app makes **one** LLM call for a briefing/review narrative and a
  bounded loop (max 5 tool rounds, then a forced answer) for an Ask question — there is no runaway
  loop that could rack up spend.
- **Without it**: the **Ask** tab shows "Assistant unavailable — add GEMINI_API_KEY" (expected,
  not a bug). Briefings and reviews still generate — they just show the plain, deterministically
  assembled facts without the LLM's narrative wrapper. No proposal, goal, or memory feature depends
  on Gemini. The app skips the key entirely if it's still the `REPLACE_ME` placeholder.

### 3. `ELEVENLABS_API_KEY` — spoken voice (text-to-speech)

- **What it is**: an API key from ElevenLabs for high-quality cloud text-to-speech, used when the
  assistant speaks back to you. (Speech-to-text — hearing *you* — is Apple's on-device Speech
  framework and needs no key; your voice audio stays on the device.)
- **Where to get it**: elevenlabs.io → account → API key.
- **Cost**: ElevenLabs has a **free tier** with a limited monthly character/credit allowance
  (enough to try it, but heavy daily voice use will exhaust it), and **paid monthly tiers** for
  more characters and better limits. Check their current plans for the exact allowance.
- **Without it**: voice still works — the app **falls back to Apple's built-in system voice**
  (`AVSpeechSynthesizer`) automatically. The fallback is also automatic *at runtime* if an
  ElevenLabs call fails mid-conversation, so a dead key or a network blip never breaks a voice
  turn; it just sounds more synthetic. The key is only about voice *quality*, never voice
  *availability*.

### 4. `CLOUDKIT_SYNC_ENABLED` — iPhone ↔ Mac sync

- **What it is**: a `true`/`false` flag that turns on syncing your data between your iPhone and
  Mac through your own private iCloud database (the same mechanism Apple's Notes/Reminders use).
  Default is `false` (or absent) → sync off, each device local-only.
- **The one real cost gate in the whole project**: turning this on requires a **paid Apple
  Developer Program membership ($99/year)**. This is Apple's rule — a free Apple ID can sideload
  the app and use HealthKit and app groups, but **cannot** enable the iCloud/CloudKit capability
  or create a CloudKit container. So free-tier sideloading and CloudKit sync are **mutually
  exclusive**; the $99/yr buys exactly one thing here: iPhone↔Mac sync. It does **not** gate the
  Mac app running, Google, Gemini, ElevenLabs, HealthKit, voice, or Shortcuts.
- **Where to get it / how to turn on**: `docs/CLOUDKIT_SETUP.md` — enroll, add the iCloud+CloudKit
  capability, create the `iCloud.com.rajatarora.PersonalOpsAgent` container, set the flag to
  `true`, build to a real device signed into iCloud. It also contains the two-device verification
  matrix.
- **Without it**: both apps run perfectly, local-only. The Mac app shows only *its own* Mac data;
  the iPhone shows only its own. Everything still works on each device; they just don't mirror each
  other. Even with the flag `true`, if iCloud is unavailable the app degrades to local-only rather
  than crashing, and the Integrations tab shows an honest "Unavailable" status with the reason.

---

## What is *not* a `Config.local` key (but you'll still set up on device)

These need no secret in the config file — they're OS permission prompts or on-device automations:

- **HealthKit** (iPhone only): a read-only permission sheet for sleep/heart-rate-adjacent metrics
  that tune goal pacing. Needs the HealthKit entitlement + usage string on a signed device build
  (added when you build to a device). Deny it and goals/daily loop work fully — pacing influence is
  just absent. Free.
- **iMessage via Shortcuts** (iPhone only): a personal "When I get a message" automation you build
  in the Shortcuts app to forward texts into the Ops Inbox as proposals. Setup in
  `docs/SHORTCUTS_SETUP.md`. Free, best-effort by design.
- **Microphone / Speech Recognition**: OS permission prompts the first time you use voice (iPhone
  and Mac). Free.

---

## How your secrets are protected

Three independent layers, all already built and tested:

1. **Never committed (gitignore)**: `Secrets/Config.local`, `Config.local`, and `*.secrets` are
   gitignored (see `.gitignore`). Only the **template** `Secrets/Config.example` — which contains
   nothing but `REPLACE_ME` placeholders — is tracked. Your real values physically cannot enter the
   repo through the normal path.
2. **Tokens live in the Keychain, not the config file**: the config file only holds the Google
   *Client ID* (public by design) and the Gemini/ElevenLabs API keys. The actual Google OAuth
   **access/refresh tokens** — the sensitive, renewable credentials — are stored in the device's
   **Keychain** (iOS/macOS secure vault), never in a file or in iCloud, and are per-device.
   `OAuthToken` redacts its own secret material in any debug description.
3. **Never logged (RedactingLogger)**: all logging funnels through `RedactingLogger`, which scrubs
   every registered secret plus known key shapes (Bearer tokens, `AIza…` Gemini keys, `GOCSPX-…`,
   `ya29.…` OAuth tokens, email addresses) before anything reaches the system log. The app
   registers your `Config` secrets with the logger at startup, before anything runs. As a backstop,
   the Gemini key rides the request URL's `key=` query (redacted) and the ElevenLabs key rides the
   `xi-api-key` header (never logged); the **model-call audit record has no field that can carry a
   token, prompt, or header by construction** — it stores only metadata (purpose, provider name,
   input *categories*, tool names, round count). This is verified by tests
   (`RedactingLoggerTests`, `ModelCallLoggingTests`).

**Bottom line**: fill in `Secrets/Config.local`, keep it out of git (it already is), and the app's
three layers keep those values out of the repository and out of every log.
