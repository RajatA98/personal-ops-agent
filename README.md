# Personal Ops Agent

A single-user, native Apple app (iOS primary, macOS companion in Phase 7B) that acts as a
daily operating layer over one person's life: morning briefing, evening capture, goal
tracking, and an LLM reasoning layer with a strict "propose, don't auto-act" safety model.

- **Product/architecture truth**: `factory/artifacts/` (`PROJECT_PLAN.md`,
  `LOCKED_DECISIONS.md`, `AGENT_DESIGN.md`, `PRD.md`)
- **Build, run, and test from a clean checkout**: [`docs/SETUP.md`](docs/SETUP.md)

## Quick start

```bash
open PersonalOpsAgent.xcodeproj   # run the app shell on an iPhone simulator (Cmd-R)
```

Validation commands (both must pass):

```bash
xcodebuild test \
  -project PersonalOpsAgent.xcodeproj \
  -scheme PersonalOpsAgent \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

cd Packages/PersonalOpsKit && swift test
```

Secrets live only in the gitignored `Secrets/Config.local` (template:
`Secrets/Config.example`) — never in the repo, never in logs.
