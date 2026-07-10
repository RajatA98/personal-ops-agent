// swift-tools-version: 6.0
import PackageDescription

// PersonalOpsKit — all module code for the Personal Ops Agent lives here so it can be
// unit-tested with `swift test` on the host (macOS) as well as compiled into the iOS
// (and, from Phase 7B, macOS) app targets. Module boundaries from PROJECT_PLAN.md are
// expressed as separate SPM targets: Core, Data, Integrations, Goals, Proposals,
// Reasoning, Voice, UI — plus Fixtures (protocol-based fakes with seed data).
let package = Package(
    name: "PersonalOpsKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15) // structure for the Phase 7B macOS target; not built yet
    ],
    products: [
        .library(name: "PersonalOpsKit", targets: [
            "Core", "Data", "Integrations", "Goals", "DailyLoop", "Proposals", "Signals", "Reasoning", "Voice", "UI"
        ]),
        // Fixtures is a first-class (non-test-only) product so both package tests and the
        // app can seed from it; real implementations replace the fakes in later phases.
        .library(name: "Fixtures", targets: ["Fixtures"])
    ],
    targets: [
        // Foundational contracts: errors, degraded states, retry, freshness, clock,
        // redacting logger, model-call audit schema, config/secrets parsing.
        .target(name: "Core"),

        // Persistence boundary. SwiftData models arrive in Phase 1 — skeleton only.
        .target(name: "Data", dependencies: ["Core"]),

        // Google Calendar / Gmail / HealthKit protocol boundary + transport DTOs.
        .target(name: "Integrations", dependencies: ["Core"]),

        // Goal engine & playbooks (Phase 3A) — skeleton only.
        .target(name: "Goals", dependencies: ["Core", "Data"]),

        // Daily Loop (Phase 3B): deterministic, LLM-free assembly of the Morning Briefing,
        // Evening Capture writes, Weekly Review rollup, and the glanceable widget snapshot.
        // Depends on Integrations for calendar/Gmail freshness + event DTOs; on Goals for
        // playbooks/slip detection; on Data for the persisted models it reads/writes.
        .target(name: "DailyLoop", dependencies: ["Core", "Data", "Integrations", "Goals"]),

        // Proposal state machine, per-type execution handlers & Ops Inbox (Phase 4A).
        // Depends on Integrations for the idempotent agent-calendar write path (the
        // create/update-event handlers), on Goals for the SchedulePreview → Proposal mapping,
        // and on DailyLoop for the Weekly Review → next-week batch. None of those depend back
        // on Proposals, so there is no cycle; the safety-critical engine/handlers stay in this
        // one module while its builders can see the upstream value types they translate.
        .target(name: "Proposals", dependencies: ["Core", "Data", "Integrations", "Goals", "DailyLoop"]),

        // Gmail-derived signals (Phase 4B): deterministic, LLM-free extraction of plan-like
        // email metadata into pending Proposals, a durable SwiftData-backed Gmail scan ledger
        // (dedupe survives relaunch), and mark-as-wrong downranking. Depends on Integrations for
        // the Gmail protocol/metadata, Data for the durable record model, and Proposals for the
        // enqueue seam + rejection-signal machinery. Nothing depends back on Signals except UI.
        .target(name: "Signals", dependencies: ["Core", "Data", "Integrations", "Proposals"]),

        // LLM reasoning boundary (Phase 5): ReasoningProvider abstraction + Prompts/.
        .target(
            name: "Reasoning",
            dependencies: ["Core"],
            resources: [.process("Prompts")]
        ),

        // Voice stack (Phase 6): STT/TTS boundary — skeleton only.
        .target(name: "Voice", dependencies: ["Core"]),

        // Shared SwiftUI surface consumed by the app shell. Depends on Data from Phase 1
        // so the app shell can browse the SwiftData-backed memory store, and on Integrations
        // from Phase 2 so the Settings screen can show connection status and connect/disconnect.
        .target(name: "UI", dependencies: ["Core", "Data", "Integrations", "Goals", "DailyLoop", "Proposals", "Signals"]),

        // Protocol-based fakes with minimal seed data, used by every later phase's tests.
        .target(name: "Fixtures", dependencies: ["Core", "Integrations", "Reasoning", "Goals"]),

        // Tests.
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "DataTests", dependencies: ["Data", "Core", "Fixtures"]),
        .testTarget(name: "FixturesTests", dependencies: ["Fixtures", "Core", "Integrations", "Reasoning"]),
        .testTarget(name: "IntegrationsTests", dependencies: ["Integrations", "Fixtures"]),
        // Phase 3A goal engine & playbooks. Depends on Integrations so the "engine performs
        // zero calendar writes" acceptance test can drive a FakeGoogleCalendarAPI and assert
        // its write-call count stays at 0.
        .testTarget(name: "GoalsTests", dependencies: ["Goals", "Core", "Data", "Fixtures", "Integrations"]),
        // Phase 3B daily loop. Depends on Fixtures for the fake calendar/Gmail seed data and
        // FakeClock, and on Integrations for the source-freshness/event DTO types.
        .testTarget(name: "DailyLoopTests",
                    dependencies: ["DailyLoop", "Core", "Data", "Goals", "Fixtures", "Integrations"]),
        // Phase 4A proposal system & Ops Inbox. Depends on Fixtures for the fake calendar
        // (idempotent-write assertions) and FakeClock, on Goals/DailyLoop for the preview and
        // weekly-review builders' inputs, and on Integrations for the calendar API + status store.
        .testTarget(name: "ProposalsTests",
                    dependencies: ["Proposals", "Core", "Data", "Goals", "DailyLoop", "Fixtures", "Integrations"]),
        // Phase 4B Gmail signals. Depends on Fixtures for the fake Gmail seed data + FakeClock,
        // on Integrations for the Gmail protocol/metadata, on Data for the durable record model,
        // and on Proposals to assert on the enqueued proposals + rejection signals.
        .testTarget(name: "SignalsTests",
                    dependencies: ["Signals", "Core", "Data", "Integrations", "Proposals", "Fixtures"])
    ]
)
