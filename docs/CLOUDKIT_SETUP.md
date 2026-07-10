# CloudKit Sync — Turning On iPhone ↔ Mac Sync (and Verifying It)

This is the step-by-step for switching on the sync that keeps your iPhone and Mac showing the
same data — the same proposals, goals, memories, and captures on both. It's written to be
followable without a technical background. Sync is **off by default**; nothing in this doc is
required to use the app on a single device.

Everything the app can prepare and prove *without* a live iCloud device has already been done and
tested (schema safety, migration, conflict handling, graceful fallback). What's left is the part
only *you*, on your real devices, can finish and confirm. That's what this doc walks through.

---

## The one thing to know first: free vs. paid Apple account

**CloudKit requires a paid Apple Developer Program membership ($99/year.)** This is Apple's rule,
not ours:

- A **free** Apple ID ("personal team") can sideload the app to your own device, but it **cannot**
  turn on the iCloud/CloudKit capability or create a CloudKit "container." If you try to sideload a
  build that declares CloudKit with a free account, signing simply fails.
- A **paid** Apple Developer Program account can enable the iCloud capability, create the container,
  and sync. Sideloading still works, and you additionally get CloudKit.

So the honest situation: the project's default (free-Apple-ID sideloading, from LOCKED_DECISIONS #2)
and CloudKit sync are **mutually exclusive**. To get iPhone↔Mac sync you must enroll in the paid
program first. Until you do, the app runs perfectly well **local-only** on each device — it just
doesn't share data between them.

If you decide **not** to pay: do nothing. Sync stays off, the app keeps working on each device
independently, and the Mac app (Phase 7B) would show only its own local data.

If you decide **to** pay: follow the rest of this doc.

---

## What's already done for you (no action needed)

- The database schema is CloudKit-safe (no unique keys, everything optional/defaulted, all
  relationships have inverses) — and there's an automatic test that *fails the build* if a future
  change breaks that, so it can't silently rot.
- The app knows how to attach CloudKit and how to **fall back to local-only without crashing** if
  iCloud isn't available — you'll see a clear "Unavailable" state in Settings rather than a crash.
- The data migration your existing on-device data needs (to the current schema) is written and
  tested against a real on-disk store.
- Conflict handling is built and tested: if you edit the same thing on both devices, the app
  surfaces it as a conflict to resolve rather than silently picking a winner; approving the same
  proposal on both devices still creates exactly one calendar event; and a duplicate email-scan
  record reconciles to one.

---

## Step-by-step: enabling sync (paid account)

### 1. Enroll in the Apple Developer Program
Go to <https://developer.apple.com/programs/> and enroll ($99/year). Wait until it's active.

### 2. Add your team to Xcode
Xcode → Settings → Accounts → add the Apple ID that has the paid membership. On the
**PersonalOpsAgent** target → **Signing & Capabilities**, pick that team under "Team."

### 3. Add the iCloud / CloudKit capability
Still on **Signing & Capabilities**:
1. Click **+ Capability**, choose **iCloud**.
2. Under **Services**, check **CloudKit**.
3. Under **Containers**, click **+** and add a container named exactly:
   `iCloud.com.rajatarora.PersonalOpsAgent`
   (This must match `DataStore.cloudKitContainerIdentifier` in the code — it already does.)

Xcode writes these entitlements into `App/App.entitlements` for you. (A ready-made copy of exactly
these keys also lives in `App/App.CloudKit.entitlements` for reference — you don't need it if you
used the Xcode button, but if you prefer, you can instead set the target build setting
`CODE_SIGN_ENTITLEMENTS = App/App.CloudKit.entitlements`.)

### 4. Turn on the app's sync flag
In `Secrets/Config.local` (create it from `Secrets/Config.example` if you haven't), set:

```
CLOUDKIT_SYNC_ENABLED=true
```

Leave it `false` (or absent) to keep sync off.

### 5. Sign in to iCloud on the device(s)
On each iPhone/Mac you'll test with, sign into **the same iCloud account** (Settings → your name),
with iCloud Drive on. Both devices must be the same Apple ID for private-database sync.

### 6. Build & run to a real device
Sync does **not** work in the Simulator or on the host — it needs a signed build on a real device
signed into iCloud. Build to your iPhone. Open **Integrations → iCloud sync** and confirm it says
**On**. If it says **Unavailable**, the row tells you why (usually: not signed into iCloud, or the
capability/container isn't set up yet) — fix that and relaunch.

---

## Verifying it actually works: the device test matrix

Real sync can only be confirmed with **two devices** — two iPhones, or (Phase 7B) an **iPhone + the
Mac app** — both signed into the same iCloud account, both running a signed build with
`CLOUDKIT_SYNC_ENABLED=true`. Run each of these and confirm the expected result. Give sync a short
window (typically seconds, occasionally a minute) to propagate.

| # | Do this | Expected result ("verified" looks like) |
|---|---------|------------------------------------------|
| 1 | **Create/approve on A, watch B.** On device A, approve a proposal that creates an agent-calendar event. | Within the sync window, device B shows the same proposal as approved, and the agent calendar has **exactly one** event (not two). |
| 2 | **Resolve on B, watch A.** On device B, correct a memory fact (e.g. change a preference). | Device A shows the corrected value; the old revision is still in History (nothing destroyed). |
| 3 | **Offline edit + reconnect.** Put device A in Airplane Mode, make a change, then reconnect. | The change appears on device B after A reconnects; no data lost. |
| 4 | **Duplicate prevention (concurrent approval).** With the same proposal visible on both, approve it on A **and** B before they sync. | Exactly **one** calendar event exists afterward (the idempotent event ID collapses the two writes). |
| 5 | **Conflicting edits.** Edit the *same* fact differently on A and B while briefly offline, then let them sync. | The app surfaces a **conflict** for that fact (two active revisions) rather than silently keeping only one — resolve it in-app. |
| 6 | **Deletion vs. edit.** "Delete" (expire) an item on A while editing it on B. | The edit is **not lost** — the item resolves to B's edit; deletion never silently wins over a concurrent edit. |

### Mac companion rows (Phase 7B — run device A = iPhone, device B = Mac app)

These extend the matrix to the iPhone↔Mac pair specifically, and cover the Mac's synced-data paths.

| # | Do this | Expected result ("verified" looks like) |
|---|---------|------------------------------------------|
| 7 | **iPhone → Mac core loop.** Approve/dismiss a proposal, complete a goal task, and add an evening-capture note on the iPhone. | The Mac app reflects all three within the sync window — the Inbox, Goals, and Briefing/Memory update without a relaunch. |
| 8 | **Mac → iPhone core loop.** Do the reverse on the Mac (approve a proposal, mark progress, ask a question that creates a pending proposal). | The iPhone reflects them; a proposal approved on the Mac hits the agent calendar exactly once (idempotent write shared with the iPhone). |
| 9 | **HealthKit pacing reaches the Mac.** Let the iPhone read HealthKit (open a goal so pacing computes), give sync a moment, then open the same goal on the Mac. | The Mac shows the same "HealthKit-influenced" pacing badge/rationale — powered by the iPhone's synced summaries, with no HealthKit on the Mac. With poor recovery on the iPhone, the Mac eases the same soft sessions. |
| 10 | **Google is per-device.** Note that the Mac needs its **own** one-time "Connect Google." | Connecting Google on the Mac does not touch the iPhone's connection, and vice versa (per-device tokens, by design). |
| 11 | **No loss/dup across a concurrent cycle.** Use both devices actively for a few minutes (approve, edit, capture on each), then let them settle. | Data converges with no duplicated events/records and no lost edits (conflicts surface per rows 4–6). |

If all rows behave as described, sync is verified. If any misbehaves, note which — SwiftData's
CloudKit layer is the least-mature area in the stack (LOCKED_DECISIONS #5), so real-device behavior
is exactly what these steps exist to pin down.

---

## Troubleshooting

- **Settings shows "Unavailable."** The device isn't signed into iCloud, or the capability/container
  isn't provisioned. Check Step 3 and Step 5. The app is running local-only meanwhile — your data is
  safe on the device.
- **"Sync is off" but you set the flag.** `CLOUDKIT_SYNC_ENABLED=true` must be in the `Config.local`
  that's bundled into the build (dev builds copy it in). Rebuild after changing it.
- **Signing fails after adding CloudKit.** You're likely still on the free team — CloudKit needs the
  paid program (see the top of this doc). To go back to free-tier sideloading temporarily, remove the
  iCloud capability (or point `CODE_SIGN_ENTITLEMENTS` back at `App/App.entitlements`) and set the
  flag to `false`.
- **Nothing syncs between devices.** Confirm both are on the **same** Apple ID and both have the flag
  on and a signed build. Private-database sync never crosses accounts.
