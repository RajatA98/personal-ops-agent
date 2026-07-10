# Setup — Build & Run from a Clean Checkout

This gets the Personal Ops Agent iOS app building, running, and passing tests from a
fresh `git clone`, using only a Mac with Xcode and a free Apple ID.

## Prerequisites

- **macOS** with **Xcode 26.x** installed (the scaffold was verified with Xcode 26.2).
  Xcode includes everything else needed: Swift toolchain, iOS SDK, and simulators.
- An iPhone simulator runtime (e.g. "iPhone 16 Pro"). Xcode installs one by default;
  more are available under Xcode → Settings → Components.
- No paid Apple Developer account required. A free Apple ID is enough for simulator use
  and for sideloading to a real device (with the free tier's 7-day resign cycle).

## Project layout

```
PersonalOpsAgent.xcodeproj    Thin iOS app project (app shell + app-level test targets)
App/
  iOS/                        App entry point (SwiftUI @main)
  Tests/AppUnitTests/         App-target unit tests (fixtures wired in)
  Tests/AppUITests/           UI launch test
Packages/PersonalOpsKit/      Local Swift Package — ALL module code lives here
  Sources/
    Core/                     Errors, degraded states, retry, freshness, clock,
                              redacting logger, model-call audit schema, Config
    Data/                     Persistence boundary (SwiftData models arrive in Phase 1)
    Integrations/             Google Calendar / Gmail / HealthKit protocol contracts
    Goals/                    Goal engine & playbooks (Phase 3A)
    Proposals/                Proposal types & lifecycle (Phase 4A)
    Reasoning/                ReasoningProvider abstraction + Prompts/ (Phase 5)
    Voice/                    STT/TTS boundary (Phase 6)
    UI/                       Shared SwiftUI views (RootView app shell)
    Fixtures/                 Fake services + FakeClock for tests (all phases)
  Tests/                      Package unit tests (run with `swift test`)
Secrets/Config.example        Template for local secrets (see below)
docs/SETUP.md                 This file
```

Most logic lives in the Swift Package so it can be tested fast on the host with
`swift test`; the Xcode project is a thin shell that links the package. The **macOS app
target** (`PersonalOpsAgentMac`, entry point `App/macOS/`) shipped in Phase 7B — it links
the same package and renders the same shared `RootView`. To build/run the Mac app and to
understand what differs from iPhone (HealthKit as synced data, per-device Google OAuth,
iOS-only iMessage/Shortcuts and widget), see **`docs/MAC_SETUP.md`**:

```bash
xcodebuild build -project PersonalOpsAgent.xcodeproj \
  -scheme PersonalOpsAgentMac -destination 'platform=macOS'
```

## 1. Configure secrets (optional in Phase 0)

Real credentials are needed starting in Phase 2 (Google), Phase 5 (Gemini), and
Phase 6 (ElevenLabs). To set them up:

```bash
cp Secrets/Config.example Secrets/Config.local
# then edit Secrets/Config.local and fill in real values
```

`Secrets/Config.local` is **gitignored** — it never enters the repository, and its
values are never written to logs (they are registered with the redacting logger at
startup). Do not put keys anywhere else. Phase 0 builds and tests fine without this file.

## 2. Build and run the app shell

Open in Xcode:

```bash
open PersonalOpsAgent.xcodeproj
```

Select the **PersonalOpsAgent** scheme and an iPhone simulator, then Run (Cmd-R).
Signing is set to **Automatic** with no team pinned — for simulator runs no signing is
needed; for a real device, add your free Apple ID under Xcode → Settings → Accounts and
pick it as the team on the PersonalOpsAgent target.

Or from the command line:

```bash
xcodebuild build \
  -project PersonalOpsAgent.xcodeproj \
  -scheme PersonalOpsAgent \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

## 3. Run the tests

App-level tests (unit + UI) on a simulator:

```bash
xcodebuild test \
  -project PersonalOpsAgent.xcodeproj \
  -scheme PersonalOpsAgent \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Package tests (fast, host-side — most tests live here):

```bash
cd Packages/PersonalOpsKit && swift test
```

Both must pass before merging any change; this is the project's validation convention
from Phase 0 onward.

## Conventions fixed in Phase 0 (later phases build on these)

- **Errors**: every failure maps to a typed `AppError` case (`Core/AppError.swift`);
  user-facing failures render a `DegradedState` — degrade visibly, never silently.
- **Retries**: use `RetryPolicy` + `AppError.isRetryable`; never hand-rolled loops.
- **Freshness**: every external source surfaces a `SourceFreshness` in the UI.
- **Time**: inject `Clock` (production `SystemClock`, tests `FakeClock`) — never call
  `Date()` directly in logic that tests need to control.
- **Logging**: only through `RedactingLogger`. Secrets, tokens, and auth headers are
  never logged; Config values are registered for scrubbing at startup.
- **Model calls**: every LLM round (Phase 5+) writes a `ModelCallAudit` record —
  metadata only, never payload.
- **Fixtures**: tests use the protocol-based fakes in `Sources/Fixtures/`
  (`FakeGoogleCalendarAPI`, `FakeGmailAPI`, `FakeHealthKitData`,
  `FakeReasoningProvider`, `FakeClock`) — never live services.
