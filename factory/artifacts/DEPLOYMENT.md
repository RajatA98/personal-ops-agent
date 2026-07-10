# Deployment — Installing Personal Ops Agent on Your Own Devices

**Status**: Complete
**Last Updated**: 2026-07-10

This app does **not** deploy to an App Store, a server, or the cloud. It "deploys" by
**sideloading** to your own iPhone and building/running on your own Mac — both signed with your
personal Apple ID. There is no backend to host, no account system, no listing to submit. The only
thing that ever leaves your devices is data you explicitly connect (Google, Gemini, ElevenLabs)
and, if you enable it, your own private iCloud sync.

This guide is the ordered path from a fresh `git clone` to daily use. It references the existing
`docs/` guides for each detailed step rather than repeating them, and ends with the on-device QA
script that validates the whole thing.

---

## Prerequisites

- **A Mac** with **Xcode 26.2** (the project was verified on 26.2; 26.x should work). Xcode brings
  the Swift toolchain, iOS SDK, and simulators.
- **An iPhone** (the target device is an iPhone 17 Pro; any iPhone on a supported iOS works — the
  app's deployment target is iOS 18.0, so anything iOS 18.0 or newer runs it). A **USB cable** (or
  same-Wi-Fi network, once the device is paired) to install from Xcode.
- **A free Apple ID** added to Xcode (Xcode → Settings → Accounts). A free ID is enough for
  everything except iPhone↔Mac CloudKit sync — see the last step.
- **(Optional, per feature)** your own Google Cloud OAuth client, a Gemini API key, an ElevenLabs
  key, and — only for sync — a paid Apple Developer Program membership. All covered in
  `ENV_SETUP.md`.

First, get a clean build passing (proves your toolchain is right before you add any credentials):

```bash
cd Packages/PersonalOpsKit && swift test          # fast host-side suite (260 tests)
xcodebuild test -project PersonalOpsAgent.xcodeproj \
  -scheme PersonalOpsAgent \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Both should pass. Full clean-checkout build/run details: `docs/SETUP.md`.

---

## Installing on your iPhone (sideloading with a free Apple ID)

1. Open `PersonalOpsAgent.xcodeproj` in Xcode.
2. Plug in your iPhone (trust the computer if prompted). Select it as the run destination (top
   bar, next to the scheme).
3. Select the **PersonalOpsAgent** target → **Signing & Capabilities** → set **Team** to your free
   Apple ID. Leave signing on **Automatic** — Xcode provisions a free development certificate for
   you.
4. Press **Run** (Cmd-R). Xcode builds, installs, and launches the app on the phone.
5. First launch on the device: iOS will refuse to open an app from an "untrusted developer" until
   you approve it. On the iPhone go to **Settings → General → VPN & Device Management → [your Apple
   ID] → Trust**. Then reopen the app.

### The 7-day reality (and how to re-sign)

A **free** Apple ID signs apps with a certificate that **expires after 7 days**. This is Apple's
free-tier limit, accepted deliberately (`LOCKED_DECISIONS.md` #2) as a reversible tradeoff to avoid
the $99/yr cost. What it means in practice:

- After ~7 days the installed app **stops launching** ("app is no longer available" / it just won't
  open). Your data is **not** lost — it's still on the device; the app just can't run until
  re-signed.
- **To re-sign**: plug the iPhone back into the Mac, open the project, and **Run** (Cmd-R) again.
  This installs a freshly signed copy over the old one, resetting the 7-day clock. Takes under a
  minute. Do this roughly weekly.
- Free Apple IDs are also limited to a handful of sideloaded apps and provisioned devices at once —
  fine for one app on one phone.
- **If the weekly re-sign becomes annoying**, the fix is the paid Apple Developer Program ($99/yr),
  which issues year-long certificates (and is the same thing that unlocks CloudKit sync). That's a
  cost decision, not a code change — revisit it whenever the friction outweighs the fee.

---

## Building and running the Mac app

The Mac has **no sideloading ceremony** — no 7-day cycle, no device provisioning. You build and run
on the same Mac you develop on.

1. In Xcode, choose the **PersonalOpsAgentMac** scheme and **My Mac** as the destination.
2. First time only: target → **Signing & Capabilities** → set **Team** to your Apple ID (free is
   fine for local Mac runs).
3. **Run** (Cmd-R). It opens as a normal Mac window with the same tabs and daily loop as the iPhone.

Command-line build check (succeeds on a clean checkout with no certificate — the Debug config signs
ad-hoc):

```bash
xcodebuild build -project PersonalOpsAgent.xcodeproj \
  -scheme PersonalOpsAgentMac -destination 'platform=macOS'
```

Full detail — the same-vs-different map, the Debug-vs-Release signing story, and why the Mac is only
*fully* useful once sync is on — is in **`docs/MAC_SETUP.md`**. Note the Mac app shows only its own
local data until you enable CloudKit sync (last step below).

---

## Activation order — turn features on one at a time

Add credentials/permissions in this sequence. Each step is independently useful and independently
verifiable, so if something misbehaves you know exactly which piece to look at. This mirrors how the
app was built (iPhone-first, integrations layered on).

1. **Run local-first (no credentials).** Install per above with an empty/absent `Config.local`.
   Create goals, generate a schedule preview, approve proposals into the Ops Inbox, do an evening
   capture, browse memory. The entire core loop works with zero external services. This proves the
   app itself is healthy before any integration can muddy the picture.

2. **Add Google OAuth.** Follow `docs/GOOGLE_SETUP.md` to create your Client ID, put it in
   `Secrets/Config.local` as `GOOGLE_OAUTH_CLIENT_ID`, rebuild, then **Integrations → Connect
   Google**. Now the briefing shows real calendar events and Gmail scanning can produce proposals.
   (Free.)

3. **Add the Gemini key.** Put `GEMINI_API_KEY` in `Config.local` (Google AI Studio), rebuild. The
   **Ask** tab goes live and briefings/reviews gain LLM narrative. (Free tier + pay-as-you-go — see
   `ENV_SETUP.md`.)

4. **Add ElevenLabs.** Put `ELEVENLABS_API_KEY` in `Config.local`, rebuild. Spoken replies use the
   high-quality voice instead of the system fallback. (Free tier limited; optional — voice already
   worked without it.)

5. **Set up Shortcuts automation (iPhone).** Follow `docs/SHORTCUTS_SETUP.md` to build the "When I
   get a message" personal automation that forwards texts into the Ops Inbox as pending proposals.
   (Free, best-effort by design.)

6. **Grant HealthKit on the device (iPhone).** On a signed device build, accept the read-only
   HealthKit permission sheet so sleep/recovery metrics tune goal pacing. Deny it and everything
   else still works — pacing influence is simply absent. (Free; requires the HealthKit
   entitlement + usage string on the device build.)

7. **Paid account + CloudKit sync (last).** Only when you want iPhone↔Mac mirroring: enroll in the
   Apple Developer Program ($99/yr), add the iCloud/CloudKit capability + container, set
   `CLOUDKIT_SYNC_ENABLED=true`, and build to real devices signed into the same iCloud account.
   Full walkthrough and the two-device verification matrix: `docs/CLOUDKIT_SETUP.md`. This is the
   only step that costs money and the only one that unlocks cross-device data.

---

## Validating the install: the on-device QA script

Once installed, run the **Manual QA Checklist in `TEST_REPORT.md` §5** — an 18-step, tap-by-tap
script written for a non-technical user. Each step says what to tap and exactly what you should
see; if a step's "You should see" doesn't happen, its number is your bug report. It covers first
launch, connecting Google, creating goals, the propose→approve safety flow, the conflict scenario,
the morning/evening daily loop (typed and voice), Gmail scanning + mark-as-wrong, forwarded texts,
memory Q&A, voice interruption, weekly review, and the optional Mac launch. That checklist is the
acceptance pass for a real install — the automated suite already proves the logic (260/260); §5
proves it on *your* hardware with *your* accounts.

---

## Troubleshooting (the predictable failures)

- **The app won't launch after about a week ("app is no longer available").** The free 7-day
  signing certificate expired. Plug in the iPhone and **Run** (Cmd-R) from Xcode to re-sign; the
  clock resets and your data is intact. See the 7-day section above. If this recurs and annoys you,
  the paid program issues year-long certificates.

- **"Untrusted Developer" on first launch.** Expected with a free Apple ID. iPhone **Settings →
  General → VPN & Device Management → [your Apple ID] → Trust**, then reopen the app.

- **Google says "hasn't verified this app," or Connect shows "Missing configuration."** The first
  is expected because your OAuth project is in "Testing" status — click **Advanced → Go to Personal
  Ops Agent → Continue**. The second means `GOOGLE_OAUTH_CLIENT_ID` isn't set, or `Config.local`
  wasn't bundled into the build (see below). Details in `docs/GOOGLE_SETUP.md`.

- **Google was working, now shows "Reconnect needed."** The permission expired or you revoked it
  (from your Google Account's third-party-access page). Tap **Reconnect** in Integrations. The app
  never silently drops your data — it asks you to reconnect.

- **Real features do nothing on the device even though `Config.local` is filled in.** On a *device*
  build, `Config.local` must be a bundled resource. In Xcode, drag `Secrets/Config.local` into the
  project and tick it under **Target Membership** for the app target (and the Mac target if used).
  Without it the app starts **unconfigured** — it runs, but integrations, Ask, and the ElevenLabs
  voice stay off. Rebuild after changing the file.

- **"Ask" tab says "Assistant unavailable."** No `GEMINI_API_KEY` (or it's still the `REPLACE_ME`
  placeholder). Add a real key and rebuild. Expected, not a bug.

- **Voice sounds robotic.** No `ELEVENLABS_API_KEY`, so it's using the Apple system-voice fallback.
  Add the key for the high-quality voice. Voice still functions either way.

- **It works in the Simulator but not on the device (or vice versa).** Expected differences: the
  Simulator can't reach the **Keychain** (so the two Keychain-roundtrip tests are skipped there and
  confirmed only on a signed/device build), and **HealthKit, the real microphone, and live audio**
  exist only on a device. Conversely, if something works on device but the Simulator lacks it,
  that's usually a permission/entitlement that only a signed device build carries. Nothing here is
  a defect — it's the simulator-vs-device boundary.

- **Mac shows different data than the iPhone.** Sync isn't on. Each device is local-only until you
  complete the paid-account CloudKit steps in `docs/CLOUDKIT_SETUP.md`. Until then this is expected.

- **Signing fails after adding CloudKit.** You're still on the free team — CloudKit needs the paid
  program. To return to free-tier sideloading, remove the iCloud capability (or point
  `CODE_SIGN_ENTITLEMENTS` back at the app-group-only entitlements) and set
  `CLOUDKIT_SYNC_ENABLED=false`. See `docs/CLOUDKIT_SETUP.md` troubleshooting.
